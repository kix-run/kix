# v2 resource constructor — Merkle DAG via builtins.toFile.
#
# Resources use real K8s names in manifests (not store paths).
# Dependency tracking uses Nix string context on out.name/selector/fqdn values.
#
# Post-processing (annotations, deploy graph, waves) is done in Phase 2
# by pipeline scripts that read the store DAG via exportReferencesGraph.
# See pipeline/ directory.

{ lib }:

rec {

  # Sentinel for cluster-scoped resources. Omits metadata.namespace.
  clusterScoped = {
    _type = "k8s-cluster-scoped";
    __toString = _: "";
    name = null;
  };

  # Recursively attach Nix string context to all string leaves in a value.
  # Non-string, non-null leaves (int, bool) pass through with a trace warning.
  attachCtxDeep = ctx: value:
    if value == null then null
    else if builtins.isString value then
      builtins.appendContext value ctx
    else if builtins.isAttrs value then
      lib.mapAttrs (_: attachCtxDeep ctx) value
    else if builtins.isList value then
      map (attachCtxDeep ctx) value
    else
      builtins.trace "warning: non-string leaf (${builtins.typeOf value}) in .manifest access — dependency not tracked"
        value;

  # Extract the 32-char base32 hash from a Nix store path.
  # /nix/store/<32-char-hash>-<name> → <32-char-hash>
  extractStoreHash = path:
    builtins.substring 11 32 (builtins.unsafeDiscardStringContext (toString path));

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
    }:
    let
      isClusterScoped = builtins.isAttrs namespace && (namespace._type or "") == "k8s-cluster-scoped";
      isNsResource = builtins.isAttrs namespace && namespace ? outPath;
      nsKey =
        if isClusterScoped then "_cluster_"
        else if isNsResource then namespace.name or "ns"
        else namespace;

      autoSelector =
        if spec ? selector.matchLabels then
          spec.selector.matchLabels
        else if labels != { } then
          labels
        else null;

      autoOut = {
        inherit name;
        fqdn =
          if isClusterScoped then name
          else "${name}.${nsKey}.svc.cluster.local";
      } // lib.optionalAttrs (autoSelector != null) {
        selector = autoSelector;
      };

      userOut = lib.mapAttrs (_: v: toString v) outputs;
    in
    {
      _type = "k8s-resource-ref";
      inherit name namespace kind apiVersion;
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
    }:
    let
      # Determine namespace handling
      isClusterScoped = builtins.isAttrs namespace && (namespace._type or "") == "k8s-cluster-scoped";
      isNsResource = builtins.isAttrs namespace && namespace ? outPath;

      # Namespace name: real K8s name with context for dependency tracking
      nsName =
        if isClusterScoped then null
        else if isNsResource then
          builtins.appendContext namespace.name (builtins.getContext "${namespace}")
        else namespace;
      nsKey =
        if isClusterScoped then "_cluster_"
        else if isNsResource then namespace.name or "ns"
        else namespace;

      # Build the K8s manifest attrset — contains real names, not store paths.
      # String values may carry Nix context from dependencies (via out.name etc.)
      # which is used for automatic dependency tracking.
      rawManifest = lib.recursiveUpdate (
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
      ) extra;

      manifestJson = builtins.toJSON rawManifest;

      # Sanitize the name for use in store paths (colons and other special
      # characters are not allowed in Nix store path names).
      sanitizedName = builtins.replaceStrings [ ":" ] [ "_" ] name;

      # Content-addressed store path. Hash depends on this resource's content
      # and all referenced resources (their store paths via string context).
      _identityPath = builtins.toFile
        "k8s-${kind}-${nsKey}-${sanitizedName}"
        manifestJson;

      # Plain path string without context (for use as attr keys, comparisons)
      _identityPathPlain = builtins.unsafeDiscardStringContext _identityPath;

      # Context containing this resource's store path
      _identityCtx = builtins.getContext "${_identityPath}";

      # Attach this resource's store path context to a plain value
      attachCtx = value:
        builtins.appendContext (toString value) _identityCtx;

      # Auto-derive selector: spec.selector.matchLabels → metadata.labels → null
      autoSelector =
        if rawManifest ? spec.selector.matchLabels then
          lib.mapAttrs (_: v: attachCtx (toString v)) rawManifest.spec.selector.matchLabels
        else if rawManifest ? metadata.labels then
          lib.mapAttrs (_: v: attachCtx (toString v)) rawManifest.metadata.labels
        else null;

      # Auto-derived outputs
      autoOut = {
        name = attachCtx name;
        fqdn =
          if isClusterScoped then attachCtx name
          else attachCtx "${name}.${nsKey}.svc.cluster.local";
        identityHash = attachCtx (extractStoreHash _identityPathPlain);
      } // lib.optionalAttrs (autoSelector != null) {
        selector = autoSelector;
      };

      # User-defined outputs override auto-derived ones.
      # null values in outputs suppress auto-derived fields.
      userOut = lib.mapAttrs (_: v:
        if v == null then null
        else attachCtx (toString v)
      ) outputs;

      mergedOut = let
        combined = autoOut // userOut;
      in lib.filterAttrs (_: v: v != null) combined;

      self = {
        _type = "k8s-resource";
        inherit apiVersion kind name namespace requires extraDeps;

        # The store path. ${resource} still embeds this path for backward compat,
        # but prefer out.name for manifest values.
        outPath = _identityPath;

        # Named outputs — auto-derived + user-defined, all with context.
        out = mergedOut;

        # Raw manifest (real names, dep contexts on strings, no self-context).
        # Used internally for serialization, hash computation, dep detection.
        inherit rawManifest;

        # Manifest re-export with this resource's own context on all strings.
        # Use for cross-resource field access: self.deployment.manifest.spec.X
        manifest = attachCtxDeep _identityCtx rawManifest;

        # Registry entry: maps store path (plain, no context) → resource metadata.
        registryEntry = {
          ${_identityPathPlain} = { inherit apiVersion kind name; namespace = nsKey; resource = self; };
        };
      };
    in
    self;

  # Creates a PackageInstance CRD — root of each package's DAG subgraph.
  # Holds references to the main resource, inverse deps, and package-level requires.
  mkPackageInstance = { instanceName, namespaceName, namespace, mainResource, packageRequires ? [], inverseDeps ? [], version ? null, labels ? {} }:
    mkResource {
      apiVersion = "kix.dev/v1alpha1";
      kind = "PackageInstance";
      name = instanceName;
      inherit namespace labels;
      annotations = {
        "kix.dev/main" = mainResource.out.name;
      }
      // lib.optionalAttrs (inverseDeps != []) {
        "kix.dev/inverse-deps" = builtins.concatStringsSep "," (map (r: "${r.kind}/${r.out.name}") inverseDeps);
      }
      // lib.optionalAttrs (packageRequires != []) {
        "kix.dev/package-requires" = builtins.concatStringsSep "," (map (r: "${r.kind}/${r.out.name}") packageRequires);
      };
      extra.spec = {
        inherit instanceName namespaceName;
      } // lib.optionalAttrs (version != null) { inherit version; };
    };

  # Build a cluster-wide registry from a list of resources.
  buildRegistry = resources:
    builtins.foldl' (acc: r: acc // r.registryEntry) { } resources;

  # Resolve a resource's namespace to a string key.
  nsOf = r:
    if r.namespace or null == null then "_cluster_"
    else if builtins.isAttrs r.namespace then
      if (r.namespace._type or "") == "k8s-cluster-scoped" then "_cluster_"
      else r.namespace.name or "_cluster_"
    else r.namespace;

  # Canonical ID for a resource (used in graph nodes and edges).
  resourceId = r: "${r.kind}/${r.name}@${nsOf r}";

  # Creates an Activation CRD — the cluster-level root of the store DAG.
  # References all PackageInstance store paths via string context in spec.instances.
  # `nix-store --tree` / `exportReferencesGraph` on this path gives the full cluster DAG.
  mkActivation = { name, instances }:
    mkResource {
      apiVersion = "kix.dev/v1alpha1";
      kind = "Activation";
      inherit name;
      namespace = clusterScoped;
      extra.spec = {
        inherit instances;
      };
    };

}
