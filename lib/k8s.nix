# v2 resource constructor — Merkle DAG via builtins.toFile.
#
# Resources use real K8s names in manifests (not store paths).
# Dependency tracking uses Nix string context on out.name/selector/fqdn values.
# Post-processing adds kix annotations (content-hash, identity-hash, depends-on)
# instead of replacing store paths with names.

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

  # Add kix annotations to a manifest for in-cluster observability.
  # Replaces postProcessManifest — manifests already contain real K8s names.
  # Strips all Nix string context from the output since dependency info
  # is now captured in the kix annotations.
  addKixAnnotations = registry: resource:
    let
      manifestJson = builtins.toJSON resource.rawManifest;
      # Content hash: hash of manifest content only (no dep context).
      # Recomputable from the live resource for drift detection.
      contentHash = builtins.hashString "sha256"
        (builtins.unsafeDiscardStringContext manifestJson);
      # Identity hash: Nix store base32 hash (Merkle — includes dep tree).
      identityHash = extractStoreHash resource.outPath;
      # Direct dependencies: k8s resource store paths found in manifest context.
      ctx = builtins.getContext manifestJson;
      k8sPaths = builtins.filter (p: builtins.hasAttr p registry) (builtins.attrNames ctx);
      depHashes = builtins.concatStringsSep "," (map extractStoreHash k8sPaths);

      annotated = lib.recursiveUpdate resource.rawManifest {
        metadata.annotations = (resource.rawManifest.metadata.annotations or {}) // {
          "kix.dev/content-hash" = contentHash;
          "kix.dev/identity-hash" = identityHash;
        } // lib.optionalAttrs (k8sPaths != []) {
          "kix.dev/depends-on" = depHashes;
        };
      };
    in
    # Strip all Nix string context — dep info is in the annotations now.
    builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.toJSON annotated));

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

  # Compute the transitive closure of a resource using the registry.
  #
  # Uses builtins.getContext on rawManifest JSON to discover deps.
  # BFS over deps + requires.
  computeClosure = registry: root:
    let
      getDeps = resource:
        let
          ctx = builtins.getContext (builtins.toJSON resource.rawManifest);
          k8sPaths = builtins.filter (p: builtins.hasAttr p registry) (builtins.attrNames ctx);
          manifestDeps = map (p: registry.${p}.resource) k8sPaths;
          requiresDeps = builtins.filter (r:
            builtins.isAttrs r && (r._type or "") == "k8s-resource"
          ) (resource.requires or []);
        in
        manifestDeps ++ requiresDeps;

      go =
        {
          seen,
          order,
          queue,
        }:
        if queue == [ ] then
          order
        else
          let
            head = builtins.head queue;
            rest = builtins.tail queue;
            ns = if head.namespace or null == null then "_cluster_" else
              if builtins.isAttrs head.namespace then
                if (head.namespace._type or "") == "k8s-cluster-scoped" then "_cluster_"
                else head.namespace.name or "_cluster_"
              else head.namespace;
            id = "${head.kind}/${head.name}@${ns}";
          in
          if builtins.hasAttr id seen then
            go {
              inherit seen order;
              queue = rest;
            }
          else
            go {
              seen = seen // {
                ${id} = true;
              };
              order = order ++ [ head ];
              queue = rest ++ (getDeps head);
            };
    in
    go {
      seen = { };
      order = [ ];
      queue = [ root ];
    };

  # Renders a closure as a Graphviz DOT digraph.
  closureToDot = registry: root:
    let
      closure' = computeClosure registry root;
      resourceId = r:
        let
          ns = if r.namespace or null == null then "cluster"
            else if builtins.isAttrs r.namespace then r.namespace.name or "cluster"
            else r.namespace;
        in
        "${r.kind}/${r.name}@${ns}";
      dotId = r: builtins.replaceStrings [ "/" "@" "-" ":" "." ] [ "_" "_" "_" "_" "_" ] (resourceId r);
      dotLabel = r: "${r.kind}\\n${r.name}";

      nodeLines = map (r: ''${dotId r} [label="${dotLabel r}"];'') closure';
      edgeLines = lib.concatMap (r:
        let
          deps = getDepsForViz registry r;
          # Parse kix.dev/requires annotation to show different edge styles
          reqAnnotation = r.rawManifest.metadata.annotations."kix.dev/requires" or null;
          reqPaths = if reqAnnotation != null then
            let ctx = builtins.getContext reqAnnotation;
            in builtins.filter (p: builtins.hasAttr p registry) (builtins.attrNames ctx)
          else [];
          reqResources = map (p: registry.${p}.resource) reqPaths;
          # Forward deps from manifest (excluding requires annotation paths)
          forwardDeps = builtins.filter (d: !(builtins.elem d reqResources)) deps;
        in
        (map (d: "${dotId r} -> ${dotId d} [style=solid, color=blue];") forwardDeps)
        ++ (map (d: "${dotId r} -> ${dotId d} [style=dashed, color=red, label=\"requires\"];") reqResources)
      ) closure';
    in
    ''
      digraph resources {
        rankdir=TB;
        node [shape=box, style=rounded, fontname="monospace", fontsize=10];
        edge [fontsize=8];
      ${builtins.concatStringsSep "\n" nodeLines}
      ${builtins.concatStringsSep "\n" edgeLines}
      }
    '';

  # Helper for visualization — get deps from context
  getDepsForViz = registry: resource:
    let
      ctx = builtins.getContext (builtins.toJSON resource.rawManifest);
      k8sPaths = builtins.filter (p: builtins.hasAttr p registry) (builtins.attrNames ctx);
    in
    map (p: registry.${p}.resource) k8sPaths;

  # Renders a closure as a human-readable tree string.
  closureToTree = registry: root:
    let
      closure' = computeClosure registry root;
      resourceId = r:
        let
          ns = if r.namespace or null == null then "cluster"
            else if builtins.isAttrs r.namespace then r.namespace.name or "cluster"
            else r.namespace;
        in
        "${r.kind}/${r.name}@${ns}";

      renderResource = r:
        let
          deps = getDepsForViz registry r;
          depLines = map (d: "  dep-> ${resourceId d}") deps;
          lines = [ (resourceId r) ] ++ depLines;
        in
        builtins.concatStringsSep "\n" lines;
    in
    builtins.concatStringsSep "\n\n" (map renderResource closure') + "\n";

  # Build a cluster-wide registry from a list of resources.
  buildRegistry = resources:
    builtins.foldl' (acc: r: acc // r.registryEntry) { } resources;

}
