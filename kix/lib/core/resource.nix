{ lib }:

rec {

  facts = import ./facts.nix { inherit lib; };

  markers = import ./markers.nix { inherit lib; };

  normalize = import ./normalize.nix { inherit lib; };

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

      # imported Services are endpoint producers too — no seal exists, but
      # the fact is pure payload, so a reference can mint it all the same.
      # This closes an old blindspot: dialing an imported Service now
      # produces a netpol edge instead of silently nothing.
      _importFactCtx =
        if kind == "Service" && (spec.selector or { }) != { } then
          facts.mkFact "endpoint" {
            inherit name;
            namespace = toString nsKey;
            selector = spec.selector;
            ports = spec.ports or [ ];
          }
        else
          { };

      attachFactCtx = value: builtins.appendContext (toString value) _importFactCtx;

      autoOut = {
        inherit name;
        fqdn = attachFactCtx (if isClusterScoped then name else "${name}.${nsKey}.svc.${clusterDomain}");
      }
      // lib.optionalAttrs (autoSelector != null) {
        selector = autoSelector;
      };

      userOut = lib.mapAttrs (_: v: attachFactCtx (toString v)) outputs;
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
      factTokens = lib.optionalAttrs (_importFactCtx != { }) { endpoint = _importFactCtx; };
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
      # per-kind terminate/conduct override from the factBehavior index
      # (CRD-owner declared via meta.factBehavior, or cluster override).
      # null = fall back to the core K8s table (facts.conducts).
      factBehavior ? null,
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

      # resolveKeeps runs here so rawManifest (and the identity JSON derived
      # from it) never carries the _kixKeep marker, and so rawManifest
      # consumers see keep-built containers the way they will render.
      rawManifest = builtins.seq _extraShadowCheck (
        normalize.resolveKeeps (
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
        )
      );

      manifestJson = builtins.toJSON rawManifest;

      # Two kinds of path ride the same context channel without being
      # derivation edges, and neither may become a depends-on entry:
      #   fact tokens          semantic claims, not identity
      #   untracked-ref marker inert proof that a name was deliberately
      #                        opted out of tracking — there is no resource
      #                        behind it, so stamping it yields a hash the
      #                        deploy DAG can never resolve and `kix health`
      #                        reports as permanently MISSING
      implicitCtxPaths = builtins.filter (
        p: lib.hasPrefix "/nix/store/" p && !facts.isFactPath p && !markers.isUntrackedRefPath p
      ) (builtins.attrNames (builtins.getContext manifestJson));
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

      # Split the context channels at the seal boundary: identity paths
      # become store references of the sealed file; fact tokens are harvested
      # for re-emission on out.* (conduction) and stripped so they never
      # enter the store DAG — facts live in eval-time context only.
      #
      # Harvest from manifestJson (pre-stamp), NOT manifestJsonWithDeps:
      # facts only ever arrive embedded in VALUES; the requires/extraDeps
      # fold contributes identity context only. Reading the withDeps string
      # here would force every dep's seal whenever any out.* field is
      # touched — a fixpoint hazard (e.g. service.out.name inside a webhook
      # config whose consumer the service itself requires).
      _conducts =
        if factBehavior != null then
          (factBehavior.endpoint or "conduct") == "conduct"
        else
          facts.conducts kind;

      _forwardedFactCtx =
        if _conducts then (facts.partitionCtx (builtins.getContext manifestJson)).facts else { };

      # terminate-declared CRs: the absorbed endpoint payloads, for the
      # instance-phase projection (netpol opens holes for the OPERAND pods
      # named by the declaration's podSelector — the resource itself has no
      # pods). Read lazily; only forced when a processor consumes it.
      _absorbedEndpointFacts =
        if factBehavior != null && (factBehavior.endpoint or "") == "terminate" then
          facts.factsOfKind "endpoint" manifestJson
        else
          [ ];

      # undeclared foreign kind (CRD) absorbing endpoint facts: kix cannot
      # know whether the controller dials them (terminate) or the resource
      # merely carries them (conduct — the current default). Warn, three-
      # valued style: declared-terminate/conduct pass silently, unknown
      # warns naming the fix. Anchored on outPath (forced at embedding).
      _undeclaredCrWarning =
        if
          factBehavior == null
          && facts.isForeignGroup apiVersion
          && facts.factsOfKind "endpoint" manifestJson != [ ]
        then
          "kix: ${kind}/${name} (${apiVersion}) absorbed endpoint fact(s) but carries no "
          + "fact behavior — kix assumes \"conduct\" (the resource carries the address "
          + "onward). If this kind's controller DIALS the endpoint (operator-managed "
          + "pods): build the CR via the typed builder (`scope.mkCR <owner>.out.crds.…`) "
          + "and declare `factBehavior = { endpoint = \"terminate\"; podSelector = cr: "
          + "{ ... }; }` on the owner's mkCRD/mkCRDRef — or, for builder-less CRs (helm, "
          + "raw kind strings), set `cluster.factBehavior.\"<group>/${kind}\"`."
        else
          null;

      manifestJsonSealed = builtins.appendContext (builtins.unsafeDiscardStringContext manifestJsonWithDeps) (facts.partitionCtx (
        builtins.getContext manifestJsonWithDeps
      )).rest;

      # toFile's filename cannot carry references — content keeps full context
      sanitizedName = builtins.unsafeDiscardStringContext (builtins.replaceStrings [ ":" ] [ "_" ] name);
      sanitizedNsKey = builtins.unsafeDiscardStringContext (toString nsKey);

      _identityPath = builtins.toFile "k8s-${kind}-${sanitizedNsKey}-${sanitizedName}" manifestJsonSealed;

      _identityPathPlain = builtins.unsafeDiscardStringContext _identityPath;

      _identityCtx = builtins.getContext "${_identityPath}";

      # Services with a selector are endpoint producers: dialing their
      # address reaches pods. The fact is pure payload — no reference to
      # this seal — so it only changes when the semantics (selector, ports,
      # namespace) change, not on every content churn.
      _isEndpointProducer =
        kind == "Service"
        && (rawManifest.spec.selector or { }) != { }
        && (rawManifest.spec.type or "ClusterIP") != "ExternalName";

      _ownFactCtx =
        if _isEndpointProducer then
          facts.mkFact "endpoint" {
            name = builtins.unsafeDiscardStringContext name;
            namespace = builtins.unsafeDiscardStringContext (toString nsKey);
            selector = rawManifest.spec.selector;
            ports = rawManifest.spec.ports or [ ];
          }
        else
          { };

      # Two attach flavors, one semantic difference:
      #   attachCtx        identity + conducted facts. "This value was
      #                    computed from me (and carries what I carry)."
      #   attachConnectCtx additionally stamps my own endpoint fact:
      #                    "using this value means dialing me."
      # name/selector are structural (naming ≠ dialing); fqdn/url and user
      # outputs are address-shaped. `facts.refOnly` is the per-use escape.
      attachCtx = value: builtins.appendContext (toString value) (_identityCtx // _forwardedFactCtx);
      attachConnectCtx =
        value: builtins.appendContext (toString value) (_identityCtx // _forwardedFactCtx // _ownFactCtx);

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
          if isClusterScoped then
            attachConnectCtx name
          else
            attachConnectCtx "${name}.${nsKey}.svc.${clusterDomain}";
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
          attachConnectCtx "${scheme}://${name}.${nsKey}.svc.${clusterDomain}${portSuffix}";
      };

      userOut = lib.mapAttrs (_: v: if v == null then null else attachConnectCtx (toString v)) outputs;

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

        outPath =
          if _undeclaredCrWarning != null then
            builtins.trace _undeclaredCrWarning _identityPath
          else
            _identityPath;

        out = mergedOut;

        # fact tokens this resource mints, for the `facts.connect` escape
        # hatch (stamp dialing intent onto a value that lacks it)
        factTokens = lib.optionalAttrs _isEndpointProducer { endpoint = _ownFactCtx; };

        # the resolved behavior + endpoint payloads absorbed by a
        # terminate-declared CR — consumed by the netpol instance processor
        # (operand CNPs read podSelector straight off the resource)
        inherit factBehavior;
        absorbedEndpointFacts = _absorbedEndpointFacts;

        rawManifest = rawManifestStamped;

        manifest = attachCtxDeep (_identityCtx // _forwardedFactCtx) rawManifestStamped;
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
      # fact behavior of this kind's controller (validated at the
      # declaration site): threaded into every CR built via mkCR, so the
      # seal knows terminate/conduct without any registry — behavior is a
      # property of the CRD, delivered along the same chain as the kind
      # name and the CRD-before-CR ordering edge.
      factBehavior ? null,
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
        }
        // lib.optionalAttrs (factBehavior != null) { inherit factBehavior; };

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
