# v2 resource constructor — Merkle DAG via builtins.toFile.
#
# Resources use real K8s names in manifests (not store paths).
# Dependency tracking uses Nix string context on out.name/selector/fqdn values.
# The CLI reads the store DAG for deploy ordering, diffing, and wave computation.

{ lib }:

rec {

  # Sentinel for cluster-scoped resources. Omits metadata.namespace.
  clusterScoped = {
    _type = "k8s-cluster-scoped";
    __toString = _: "";
    name = null;
  };

  # Strip kix-internal metadata from a manifest fragment.
  #
  # Convention: the reserved attrset key `_kix` carries kix-internal metadata
  # on any K8s fragment (volume entry, env entry, secretRef, etc.). It mirrors
  # the `_module` reserved-key pattern from NixOS modules. Validators that run
  # before serialization (e.g. checkSecretRefs) read `_kix.*` directly; this
  # stripper removes every `_kix` key recursively right before the manifest is
  # rendered to JSON, so no marker ever leaks into K8s.
  #
  # Adding a new piece of internal metadata never requires touching the
  # stripper — just write it under `_kix` on the fragment that needs it.
  stripKixMeta =
    value:
    if builtins.isAttrs value then
      lib.mapAttrs (_: stripKixMeta) (removeAttrs value [ "_kix" ])
    else if builtins.isList value then
      map stripKixMeta value
    else
      value;

  # Recursively attach Nix string context to all string leaves in a value.
  # Non-string, non-null leaves (int, bool) pass through with a trace warning.
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

  # Extract the 32-char base32 hash from a Nix store path.
  # /nix/store/<32-char-hash>-<name> → <32-char-hash>
  extractStoreHash =
    path: builtins.substring 11 32 (builtins.unsafeDiscardStringContext (toString path));

  # Lightweight resource reference for import mode.
  # Computes out (name, fqdn, selector, outputs) without creating store paths
  # or manifests. Used as a drop-in replacement for mkResource when evaluating
  # imported packages — the package code is identical, only scope.mkResource differs.
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

  # Creates a K8s resource as a content-addressed store path.
  #
  # namespace can be:
  #   - A namespace resource (has outPath) → uses real name, auto-dep via context
  #   - clusterScoped sentinel → omits metadata.namespace
  #   - A plain string → uses directly
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
      # Determine namespace handling
      isClusterScoped = builtins.isAttrs namespace && (namespace._type or "") == "k8s-cluster-scoped";
      isNsResource = builtins.isAttrs namespace && namespace ? outPath;

      # Namespace name: real K8s name with context for dependency tracking
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

      # --- extra.* shadowing check ---
      # `extra` is a passthrough for K8s fields kix doesn't model explicitly
      # (e.g. stackgres-specific spec keys). It must NOT override fields that
      # kix already manages as whole sub-trees via dedicated args (spec, data,
      # stringData), because that silently bypasses auto-derived DI tracking
      # on spec.selector and makes the merge order confusing.
      #
      # `metadata.labels` and `metadata.annotations` are intentionally NOT in
      # this list: `lib.recursiveUpdate` merges them additively with the
      # scope-injected labels/annotations, which is a valid and supported
      # pattern (e.g. grafana datasourcesConfigMap tagging with
      # `extra.metadata.labels.grafana_datasource = "1"`).
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

      # Build the K8s manifest attrset — contains real names, not store paths.
      # String values may carry Nix context from dependencies (via out.name etc.)
      # which is used for automatic dependency tracking.
      #
      # `stripKixMeta` removes any `_kix` reserved-key markers (used for
      # cross-namespace validation, provenance, etc.) recursively, so no
      # internal metadata ever reaches the rendered K8s manifest.
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

      # --- Dependency annotation (kix.dev/depends-on) ---
      # Tagged format: bare hash = implicit (interpolation), requires:<hash>, extra:<hash>
      implicitCtxPaths = builtins.filter (p: lib.hasPrefix "/nix/store/" p) (
        builtins.attrNames (builtins.getContext manifestJson)
      );
      implicitEntries = map extractStoreHash implicitCtxPaths;

      requiresResources = builtins.filter (dep: builtins.isAttrs dep && dep ? outPath) requires;
      requiresEntries = map (dep: "requires:${extractStoreHash dep}") requiresResources;

      extraResources = builtins.filter (dep: builtins.isAttrs dep && dep ? outPath) extraDeps;
      extraEntries = map (dep: "extra:${extractStoreHash dep}") extraResources;

      depEntries = implicitEntries ++ requiresEntries ++ extraEntries;

      # Stamp depends-on into manifest annotations (if any deps exist)
      rawManifestStamped =
        if depEntries == [ ] then
          rawManifest
        else
          lib.recursiveUpdate rawManifest {
            metadata.annotations."kix.dev/depends-on" = builtins.concatStringsSep "," depEntries;
          };

      manifestJsonStamped = builtins.toJSON rawManifestStamped;

      # Collect store contexts from requires and extraDeps so they influence
      # the content-addressed store path (Nix store DAG edges).
      allDeps = requires ++ extraDeps;
      depContexts = builtins.foldl' (
        acc: dep: if builtins.isAttrs dep && dep ? outPath then acc // builtins.getContext "${dep}" else acc
      ) { } allDeps;

      # Append dep contexts to manifestJson
      manifestJsonWithDeps = builtins.appendContext manifestJsonStamped depContexts;

      # Sanitize the name for use in store paths (colons and other special
      # characters are not allowed in Nix store path names).
      sanitizedName = builtins.replaceStrings [ ":" ] [ "_" ] name;

      # Content-addressed store path. Hash depends on this resource's content
      # and all referenced resources (their store paths via string context).
      _identityPath = builtins.toFile "k8s-${kind}-${nsKey}-${sanitizedName}" manifestJsonWithDeps;

      # Plain path string without context (for use as attr keys, comparisons)
      _identityPathPlain = builtins.unsafeDiscardStringContext _identityPath;

      # Context containing this resource's store path
      _identityCtx = builtins.getContext "${_identityPath}";

      # Attach this resource's store path context to a plain value
      attachCtx = value: builtins.appendContext (toString value) _identityCtx;

      # Auto-derive selector: spec.selector.matchLabels → metadata.labels → null
      autoSelector =
        if rawManifest ? spec.selector.matchLabels then
          lib.mapAttrs (_: v: attachCtx (toString v)) rawManifest.spec.selector.matchLabels
        else if rawManifest ? metadata.labels then
          lib.mapAttrs (_: v: attachCtx (toString v)) rawManifest.metadata.labels
        else
          null;

      # Auto-derived outputs
      autoOut = {
        name = attachCtx name;
        fqdn =
          if isClusterScoped then attachCtx name else attachCtx "${name}.${nsKey}.svc.${clusterDomain}";
        identityHash = attachCtx (extractStoreHash _identityPathPlain);
      }
      // lib.optionalAttrs (autoSelector != null) {
        selector = autoSelector;
      };

      # User-defined outputs override auto-derived ones.
      # null values in outputs suppress auto-derived fields.
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

        # The store path. ${resource} still embeds this path for backward compat,
        # but prefer out.name for manifest values.
        outPath = _identityPath;

        # Named outputs — auto-derived + user-defined, all with context.
        out = mergedOut;

        # Raw manifest (real names, dep contexts on strings, no self-context).
        # Includes kix.dev/depends-on annotation when deps exist.
        rawManifest = rawManifestStamped;

        # Manifest re-export with this resource's own context on all strings.
        # Use for cross-resource field access: self.deployment.manifest.spec.X
        manifest = attachCtxDeep _identityCtx rawManifestStamped;
      };
    in
    self;

  # --- Secret helpers -----------------------------------------------------------
  # Shared out helpers for mkSecret and mkSecretRef. Returns an attrset with
  # keyRef, mkEnv, envFrom, volume — all producing K8s-native structures with
  # string context for automatic dependency tracking.
  #
  # keyRef and mkEnv validate requested keys against the declared keys list
  # at nix build time, catching typos before pod startup.
  mkSecretHelpers =
    {
      name, # K8s secret name (plain, context added by attachCtx)
      keys, # list of declared key names
      type, # K8s secret type (e.g. "Opaque")
      attachCtx, # function: string -> string-with-context
      namespace, # namespace this secret lives in (for cross-ns validation)
      reflected ? false, # if true, secret is mirrored cross-namespace by the
      # emberstack reflector controller — relax the same-namespace check in
      # checkNamespacedRefs since a local copy will exist in the consumer's
      # namespace by the time pods start.
    }:
    let
      ctxName = attachCtx name;
      # Reserved-key marker — read by checkSecretRefs in mkWorkload, stripped
      # by stripKixMeta before manifest serialization.
      kixMeta = {
        _kix = {
          inherit namespace;
          source = "secret";
        }
        // lib.optionalAttrs reflected { reflected = true; };
      };
      helpers = {
        inherit keys type;

        # Single key reference → { valueFrom.secretKeyRef = { name, key }; }
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

        # Map env var names to secret keys → [ { name, valueFrom.secretKeyRef } ]
        mkEnv =
          mapping:
          lib.mapAttrsToList (envName: secretKey: (helpers.keyRef secretKey) // { name = envName; }) mapping;

        # Inject all keys as env vars → { secretRef = { name }; }
        envFrom = {
          secretRef = {
            name = ctxName;
          };
        }
        // kixMeta;

        # Mount as volume → { name, secret.secretName }
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

  # --- kix-internal CRDs --------------------------------------------------------
  # Registered once per cluster; every PackageInstance / Activation auto-depends
  # on the corresponding CRD so `kubectl apply` works in the correct order.

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

  # Creates a PackageInstance CRD — root of each package's DAG subgraph.
  # Holds references to the root resource, inverse deps, package-level requires,
  # and post-hooks (resources deployed after all other package resources complete).
  mkPackageInstance =
    {
      instanceName,
      namespaceName,
      namespace,
      mainResource,
      packageRequires ? [ ],
      postHooks ? [ ],
      inverseDeps ? [ ],
      version ? null,
      labels ? { },
      extraAnnotations ? { },
    }:
    let
      resolvedVersion =
        if version == null then
          builtins.trace "warning: package ${instanceName} has no version set" "<undefined>"
        else
          version;
    in
    mkResource {
      apiVersion = "kix.dev/v1alpha1";
      kind = "PackageInstance";
      name = instanceName;
      inherit namespace labels;
      requires = [ kixCRDs.packageInstance ];
      annotations = {
        "kix.dev/root" = mainResource.out.name;
      }
      // lib.optionalAttrs (inverseDeps != [ ]) {
        "kix.dev/inverse-deps" = builtins.concatStringsSep "," (
          map (r: "${r.kind}/${r.out.name}") inverseDeps
        );
      }
      // lib.optionalAttrs (packageRequires != [ ]) {
        "kix.dev/package-requires" = builtins.concatStringsSep "," (
          map (r: "${r.kind}/${r.out.name}") packageRequires
        );
      }
      // lib.optionalAttrs (postHooks != [ ]) {
        "kix.dev/post-hooks" = builtins.concatStringsSep "," (map (r: "${r.kind}/${r.out.name}") postHooks);
      }
      // extraAnnotations;
      extra.spec = {
        inherit instanceName namespaceName;
        version = resolvedVersion;
      };
    };

  # Resolve a resource's namespace to a string key.
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

  # Canonical ID for a resource (used in graph nodes and edges).
  resourceId = r: "${r.kind}/${r.name}@${nsOf r}";

  # Generate CR builders for a CRD. Used by scope.mkCRD and scope.mkCRDRef.
  #
  # Returns { cr, mkCR } — two builder styles for creating custom resources.
  # Dependency tracking uses `requires` (the CRD/ref is added to the CR's requires list)
  # rather than string context on apiVersion/kind.
  #
  # crdOrRef: the CRD resource or CRD ref (has outPath, used in requires for DAG tracking)
  # group/kind/version: CRD metadata for constructing the CR's apiVersion + kind
  # crdScope: "Namespaced" or "Cluster" — determines which scope method mkCR uses
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

      # Pipe-friendly transformer: stamps apiVersion + kind onto resource args
      # and adds the CRD to requires for dependency tracking.
      cr =
        args:
        args
        // {
          apiVersion = crApiVersion;
          kind = crKind;
          requires = (args.requires or [ ]) ++ [ crdOrRef ];
        };

      # Full builder: takes consumer scope, auto-routes by CRD scope.
      # Internally: cr args |> scope.mkResource or scope.mkClusterResource
      # Curried — `crd.out.mkCR scope` returns an args->resource function.
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

  # Creates an Activation CRD — the cluster-level root of the store DAG.
  # References all PackageInstance store paths via string context in spec.instances.
  # `nix-store --tree` / `exportReferencesGraph` on this path gives the full cluster DAG.
  mkActivation =
    {
      name,
      instances,
      extraDeps ? [ ],
    }:
    mkResource {
      apiVersion = "kix.dev/v1alpha1";
      kind = "Activation";
      inherit name;
      labels = {
        "app.kubernetes.io/managed-by" = "kix";
      };
      requires = [ kixCRDs.activation ];
      extraDeps = extraDeps;
      namespace = clusterScoped;
      extra.spec = {
        inherit instances;
      };
    };

}
