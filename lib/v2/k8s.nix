# v2 resource constructor — Merkle DAG via builtins.toFile.
#
# Replaces v1's resource.nix + refs.nix + resolve.nix (~425 lines) with native
# Nix string context tracking. Resources are store paths; ${resource} embeds the
# path and Nix tracks the dependency automatically.
#
# No tree walker, no custom refs, no tracked strings.

{ lib }:

rec {

  # Sentinel for cluster-scoped resources. Omits metadata.namespace.
  clusterScoped = {
    _type = "k8s-cluster-scoped";
    __toString = _: "";
    name = null;
  };

  # Creates a K8s resource as a content-addressed store path.
  #
  # namespace can be:
  #   - A namespace resource (has outPath) → embeds store path, auto-dep
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
      nsName =
        if isClusterScoped then null
        else if isNsResource then "${namespace}"  # embeds store path → auto-dep
        else namespace;
      nsKey =
        if isClusterScoped then "_cluster_"
        else if isNsResource then namespace.name or "ns"
        else namespace;

      # Note: requires are NOT encoded as annotations on individual resources
      # because it can create circular dependencies (e.g., SS requires HPA,
      # HPA references SS via ${} → cycle if both affect store paths).
      # Instead, all requires are collected and placed on the PackageInstance CRD.

      # Build the K8s manifest attrset
      manifest = lib.recursiveUpdate (
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

      manifestJson = builtins.toJSON manifest;

      # Sanitize the name for use in store paths (colons and other special
      # characters are not allowed in Nix store path names).
      sanitizedName = builtins.replaceStrings [ ":" ] [ "_" ] name;

      # Content-addressed store path. Hash depends on this resource's content
      # and all referenced resources (their store paths in manifestJson).
      _identityPath = builtins.toFile
        "k8s-${kind}-${nsKey}-${sanitizedName}"
        manifestJson;

      # Plain path string without context (for use as attr keys, comparisons)
      _identityPathPlain = builtins.unsafeDiscardStringContext _identityPath;

      # Attach this resource's store path context to a plain value
      attachCtx = value:
        builtins.appendContext (toString value) (builtins.getContext "${_identityPath}");

      self = {
        _type = "k8s-resource";
        inherit apiVersion kind name namespace requires extraDeps;

        # The store path. ${resource} embeds this path, Nix tracks context.
        outPath = _identityPath;

        # FQDN — the DNS name consumers need. Carries this resource's context.
        fqdn =
          if isClusterScoped then attachCtx name
          else attachCtx "${name}.${nsKey}.svc.cluster.local";

        # Named outputs — each carries this resource's context.
        out = lib.mapAttrs (_: v: attachCtx (toString v)) outputs;

        # Raw manifest (with store paths, pre-post-processing).
        inherit manifest;
        rawManifest = manifest;

        # Registry entry: maps store path (plain, no context) → resource metadata.
        registryEntry = {
          ${_identityPathPlain} = { inherit apiVersion kind name; namespace = nsKey; resource = self; };
        };
      };
    in
    self;

  # Post-process a manifest: replace store paths with K8s names using the registry.
  # This handles ALL string values including kix.dev/* annotations.
  postProcessManifest = registry: manifest:
    let
      json = builtins.toJSON manifest;
      ctx = builtins.getContext json;
      k8sPaths = builtins.filter (p: builtins.hasAttr p registry) (builtins.attrNames ctx);
      replaced = builtins.replaceStrings
        k8sPaths
        (map (p: registry.${p}.name) k8sPaths)
        json;
    in
    builtins.fromJSON (builtins.unsafeDiscardStringContext replaced);

  # Creates a PackageInstance CRD — root of each package's DAG subgraph.
  # Holds references to the main resource, inverse deps, and package-level requires.
  # All references use "${resource}" interpolation → store paths tracked → full DAG edges.
  mkPackageInstance = { instanceName, namespaceName, namespace, mainResource, inverseDeps ? [], packageRequires ? [], version ? null, labels ? {} }:
    mkResource {
      apiVersion = "kix.dev/v1alpha1";
      kind = "PackageInstance";
      name = instanceName;
      inherit namespace labels;
      annotations = {
        "kix.dev/main" = "${mainResource}";
      }
      // lib.optionalAttrs (inverseDeps != []) {
        "kix.dev/inverse-deps" = builtins.concatStringsSep "," (map (r: "${r}") inverseDeps);
      }
      // lib.optionalAttrs (packageRequires != []) {
        "kix.dev/package-requires" = builtins.concatStringsSep "," (map (r: "${r}") packageRequires);
      };
      extra.spec = {
        inherit instanceName namespaceName;
      } // lib.optionalAttrs (version != null) { inherit version; };
    };

  # Compute the transitive closure of a resource using the registry.
  #
  # Uses builtins.getContext on manifest JSON to discover deps (replaces v1 tree walker).
  # BFS over deps + requires, same algorithm as v1.
  computeClosure = registry: root:
    let
      getDeps = resource:
        let
          ctx = builtins.getContext (builtins.toJSON resource.rawManifest);
          k8sPaths = builtins.filter (p: builtins.hasAttr p registry) (builtins.attrNames ctx);
        in
        map (p: registry.${p}.resource) k8sPaths;

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
          reqAnnotation = r.manifest.metadata.annotations."kix.dev/requires" or null;
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
