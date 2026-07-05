{ lib }:

rec {

  clusterScoped = {
    _type = "k8s-cluster-scoped";
    __toString = _: "";
    name = null;
  };

  validKixKeys = [
    "namespace"
    "source"
    "reflected"
    "serviceAccountNamespace"
  ];

  stripKixMeta =
    value:
    if builtins.isAttrs value then
      let
        _kixCheck =
          if value ? _kix then
            let
              unknown = builtins.filter (k: !(builtins.elem k validKixKeys)) (builtins.attrNames value._kix);
            in
            if unknown != [ ] then
              throw "unknown _kix marker key(s): ${builtins.concatStringsSep ", " unknown}. "
              + "Valid keys: ${builtins.concatStringsSep ", " validKixKeys}. "
              + "This is almost always a typo — check the fragment that set _kix."
            else
              null
          else
            null;
      in
      builtins.seq _kixCheck (lib.mapAttrs (_: stripKixMeta) (removeAttrs value [ "_kix" ]))
    else if builtins.isList value then
      map stripKixMeta value
    else
      value;

  attachCtxDeep =
    ctx: value:
    if value == null then
      null
    else if builtins.isString value then
      builtins.appendContext value ctx
    else if builtins.isAttrs value then
      lib.mapAttrs (_: attachCtxDeep ctx) value
    else if builtins.isList value then
      map (attachCtxDeep ctx) value
    else
      builtins.trace "warning: non-string leaf (${builtins.typeOf value}) in .manifest access — dependency not tracked" value;

  extractStoreHash =
    path: builtins.substring 11 32 (builtins.unsafeDiscardStringContext (toString path));

  mkImportResource =
    {
      name,
      namespace,
      apiVersion ? "",
      kind ? "",
      spec ? { },
      data ? { },
      stringData ? { },
      labels ? { },
      annotations ? { },
      outputs ? { },
      requires ? [ ],
      extraDeps ? [ ],
      extra ? { },
      clusterDomain ? "cluster.local",
    }:
    let
      isClusterScoped = builtins.isAttrs namespace && (namespace._type or "") == "k8s-cluster-scoped";
      isNsResource = builtins.isAttrs namespace && namespace ? outPath;
      nsKey =
        if isClusterScoped then
          "_cluster_"
        else if isNsResource then
          namespace.name or "ns"
        else
          namespace;

      autoSelector =
        if spec ? selector.matchLabels then
          spec.selector.matchLabels
        else if labels != { } then
          labels
        else
          null;

      autoOut = {
        inherit name;
        fqdn = if isClusterScoped then name else "${name}.${nsKey}.svc.${clusterDomain}";
      }
      // lib.optionalAttrs (autoSelector != null) {
        selector = autoSelector;
      };

      userOut = lib.mapAttrs (_: v: toString v) outputs;
    in
    {
      _type = "k8s-resource-ref";
      inherit
        name
        namespace
        kind
        apiVersion
        ;
      out = autoOut // userOut;
      requires = [ ];
    };

  mkResource =
    {
      apiVersion,
      kind,
      name,
      namespace,
      spec ? { },
      data ? { },
      stringData ? { },
      labels ? { },
      annotations ? { },
      outputs ? { },
      requires ? [ ],
      extraDeps ? [ ],
      extra ? { },
      clusterDomain ? "cluster.local",
    }:
    let
      isClusterScoped = builtins.isAttrs namespace && (namespace._type or "") == "k8s-cluster-scoped";
      isNsResource = builtins.isAttrs namespace && namespace ? outPath;

      nsName =
        if isClusterScoped then
          null
        else if isNsResource then
          builtins.appendContext namespace.name (builtins.getContext "${namespace}")
        else
          namespace;
      nsKey =
        if isClusterScoped then
          "_cluster_"
        else if isNsResource then
          namespace.name or "ns"
        else
          namespace;

      _managedPaths = [
        [ "apiVersion" ]
        [ "kind" ]
        [
          "metadata"
          "name"
        ]
        [
          "metadata"
          "namespace"
        ]
      ]
      ++ lib.optional (spec != { }) [ "spec" ]
      ++ lib.optional (data != { }) [ "data" ]
      ++ lib.optional (stringData != { }) [ "stringData" ];

      _hasPath =
        attrs: path:
        if path == [ ] then
          true
        else if !(builtins.isAttrs attrs) then
          false
        else
          let
            h = builtins.head path;
            t = builtins.tail path;
          in
          (attrs ? ${h}) && (t == [ ] || _hasPath attrs.${h} t);

      _shadowedPaths = builtins.filter (p: _hasPath extra p) _managedPaths;

      _extraShadowCheck =
        if _shadowedPaths != [ ] then
          throw "k8s-resource '${kind}/${name}': extra.* shadows managed field(s) "
          + "${builtins.concatStringsSep ", " (map (p: builtins.concatStringsSep "." p) _shadowedPaths)}. "
          + "Fields under `spec`, `data`, `stringData`, `metadata.{name,namespace,labels,annotations}` "
          + "are set via dedicated args so kix can attach DI tracking. Move your customizations into "
          + "those args (e.g. `spec = { ... }` instead of `extra.spec = { ... }`), or use `extra` only "
          + "for sibling fields kix doesn't manage explicitly."
        else
          null;

      rawManifest = builtins.seq _extraShadowCheck (
        stripKixMeta (
          lib.recursiveUpdate (
            {
              inherit apiVersion kind;
              metadata = {
                inherit name;
              }
              // lib.optionalAttrs (nsName != null) { namespace = nsName; }
              // lib.optionalAttrs (labels != { }) { inherit labels; }
              // lib.optionalAttrs (annotations != { }) { inherit annotations; };
            }
            // lib.optionalAttrs (spec != { }) { inherit spec; }
            // lib.optionalAttrs (data != { }) { inherit data; }
            // lib.optionalAttrs (stringData != { }) { inherit stringData; }
          ) extra
        )
      );

      manifestJson = builtins.toJSON rawManifest;

      implicitCtxPaths = builtins.filter (p: lib.hasPrefix "/nix/store/" p) (
        builtins.attrNames (builtins.getContext manifestJson)
      );
      implicitEntries = map extractStoreHash implicitCtxPaths;

      requiresResources = builtins.filter (dep: builtins.isAttrs dep && dep ? outPath) requires;
      requiresEntries = map (dep: "requires:${extractStoreHash dep}") requiresResources;

      extraResources = builtins.filter (dep: builtins.isAttrs dep && dep ? outPath) extraDeps;
      extraEntries = map (dep: "extra:${extractStoreHash dep}") extraResources;

      depEntries = implicitEntries ++ requiresEntries ++ extraEntries;

      rawManifestStamped =
        if depEntries == [ ] then
          rawManifest
        else
          lib.recursiveUpdate rawManifest {
            metadata.annotations."kix.dev/depends-on" = builtins.concatStringsSep "," depEntries;
          };

      manifestJsonStamped = builtins.toJSON rawManifestStamped;

      allDeps = requires ++ extraDeps;
      depContexts = builtins.foldl' (
        acc: dep: if builtins.isAttrs dep && dep ? outPath then acc // builtins.getContext "${dep}" else acc
      ) { } allDeps;

      manifestJsonWithDeps = builtins.appendContext manifestJsonStamped depContexts;

      # toFile's filename cannot carry references — content keeps full context
      sanitizedName = builtins.unsafeDiscardStringContext (builtins.replaceStrings [ ":" ] [ "_" ] name);
      sanitizedNsKey = builtins.unsafeDiscardStringContext (toString nsKey);

      _identityPath = builtins.toFile "k8s-${kind}-${sanitizedNsKey}-${sanitizedName}" manifestJsonWithDeps;

      _identityPathPlain = builtins.unsafeDiscardStringContext _identityPath;

      _identityCtx = builtins.getContext "${_identityPath}";

      attachCtx = value: builtins.appendContext (toString value) _identityCtx;

      autoSelector =
        if rawManifest ? spec.selector.matchLabels then
          lib.mapAttrs (_: v: attachCtx (toString v)) rawManifest.spec.selector.matchLabels
        else if rawManifest ? metadata.labels then
          lib.mapAttrs (_: v: attachCtx (toString v)) rawManifest.metadata.labels
        else
          null;

      autoOut = {
        name = attachCtx name;
        fqdn =
          if isClusterScoped then attachCtx name else attachCtx "${name}.${nsKey}.svc.${clusterDomain}";
        identityHash = attachCtx (extractStoreHash _identityPathPlain);
      }
      // lib.optionalAttrs (autoSelector != null) {
        selector = autoSelector;
      }
      // lib.optionalAttrs (kind == "Service" && rawManifest ? spec.ports) {
        ports = rawManifest.spec.ports;

        url =
          {
            scheme ? "http",
            port ? null,
          }:
          let
            firstPort =
              if rawManifest.spec.ports != [ ] then (builtins.head rawManifest.spec.ports).port or null else null;
            effectivePort = if port != null then port else firstPort;
            portSuffix = if effectivePort != null then ":${toString effectivePort}" else "";
          in
          attachCtx "${scheme}://${name}.${nsKey}.svc.${clusterDomain}${portSuffix}";
      };

      userOut = lib.mapAttrs (_: v: if v == null then null else attachCtx (toString v)) outputs;

      mergedOut =
        let
          combined = autoOut // userOut;
        in
        lib.filterAttrs (_: v: v != null) combined;

      self = {
        _type = "k8s-resource";
        inherit
          apiVersion
          kind
          name
          namespace
          requires
          extraDeps
          ;

        outPath = _identityPath;

        out = mergedOut;

        rawManifest = rawManifestStamped;

        manifest = attachCtxDeep _identityCtx rawManifestStamped;
      };
    in
    self;

  mkSecretHelpers =
    {
      name,
      keys,
      type,
      attachCtx,
      namespace,
      reflected ? false,
    }:
    let
      ctxName = attachCtx name;
      kixMeta = {
        _kix = {
          inherit namespace;
          source = "secret";
        }
        // lib.optionalAttrs reflected { reflected = true; };
      };
      helpers = {
        inherit keys type;

        keyRef =
          key:
          if !(builtins.elem key keys) then
            throw "secret \"${name}\" does not declare key \"${key}\"\n  declared keys: ${builtins.concatStringsSep ", " keys}"
          else
            {
              valueFrom.secretKeyRef = {
                name = ctxName;
                inherit key;
              };
            }
            // kixMeta;

        mkEnv =
          mapping:
          lib.mapAttrsToList (envName: secretKey: (helpers.keyRef secretKey) // { name = envName; }) mapping;

        envFrom = {
          secretRef = {
            name = ctxName;
          };
        }
        // kixMeta;

        volume =
          volName:
          {
            name = volName;
            secret = {
              secretName = ctxName;
            };
          }
          // kixMeta;
      };
    in
    helpers;

  mkKixCRD =
    {
      kind,
      plural,
      scope ? "Namespaced",
    }:
    mkResource {
      apiVersion = "apiextensions.k8s.io/v1";
      kind = "CustomResourceDefinition";
      name = "${plural}.kix.dev";
      namespace = clusterScoped;
      labels = {
        "app.kubernetes.io/managed-by" = "kix";
      };
      extra.spec = {
        group = "kix.dev";
        inherit scope;
        names = {
          inherit kind plural;
          singular = lib.toLower kind;
          listKind = "${kind}List";
        };
        versions = [
          {
            name = "v1alpha1";
            served = true;
            storage = true;
            subresources.status = { };
            schema.openAPIV3Schema = {
              type = "object";
              properties = {
                apiVersion.type = "string";
                kind.type = "string";
                metadata.type = "object";
                spec = {
                  type = "object";
                  "x-kubernetes-preserve-unknown-fields" = true;
                };
                status = {
                  type = "object";
                  "x-kubernetes-preserve-unknown-fields" = true;
                };
              };
            };
          }
        ];
      };
    };

  kixCRDs = {
    packageInstance = mkKixCRD {
      kind = "PackageInstance";
      plural = "packageinstances";
    };
    activation = mkKixCRD {
      kind = "Activation";
      plural = "activations";
      scope = "Cluster";
    };
  };

  nsOf =
    r:
    if r.namespace or null == null then
      "_cluster_"
    else if builtins.isAttrs r.namespace then
      if (r.namespace._type or "") == "k8s-cluster-scoped" then
        "_cluster_"
      else
        r.namespace.name or "_cluster_"
    else
      r.namespace;

  resourceId = r: "${r.kind}/${r.name}@${nsOf r}";

  mkCRDBuilders =
    {
      crdOrRef,
      group,
      kind,
      version,
      crdScope,
    }:
    let
      crApiVersion = "${group}/${version}";
      crKind = kind;

      cr =
        args:
        args
        // {
          apiVersion = crApiVersion;
          kind = crKind;
          requires = (args.requires or [ ]) ++ [ crdOrRef ];
        };

      mkCR =
        consumerScope: args:
        let
          enriched = cr args;
        in
        if crdScope == "Cluster" then
          consumerScope.mkClusterResource enriched
        else
          consumerScope.mkResource enriched;
    in
    {
      inherit cr mkCR;
    };

}
