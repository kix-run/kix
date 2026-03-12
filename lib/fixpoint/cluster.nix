# Cluster composition — the outer fixpoint.
#
# The cluster is a self-referential set of packages, composed via overlays.
# This is the same pattern as nixpkgs: `lib.fix (self: { pkg1 = ...; pkg2 = ...; })`
# with overlays that compose left-to-right.
#
# Cross-package references work through the outer fixpoint: when package A
# receives `self.coredns` from the package set, it gets the FINAL coredns
# (after all overlays). If an overlay swaps coredns, A automatically gets
# the modified version.

{ lib }:

let
  # Shared identity helpers for resource nodes and edges.
  resourceId =
    r:
    let
      ns = if r.namespace or null == null then "cluster" else r.namespace;
    in
    "${r.kind}/${r.name}@${ns}";

  dotId = r: builtins.replaceStrings [ "/" "@" "-" ":" "." ] [ "_" "_" "_" "_" "_" ] (resourceId r);

  dotLabel = r: "${r.kind}\\n${r.name}";
in

rec {

  # Applies a list of overlays to a base package set function.
  #
  # Each overlay: self -> super -> { ... overridden packages ... }
  #   - self: the FINAL package set (after all overlays)
  #   - super: the package set from the previous layer
  #
  # Overlays compose left-to-right, identical to nixpkgs overlays.
  applyOverlays =
    overlays: base:
    let
      applied = lib.foldl' (
        prev: overlay: self:
        let
          super = prev self;
        in
        super // (overlay self super)
      ) base overlays;
    in
    lib.fix applied;

  # Creates a cluster from a base package set and overlays.
  #
  # Arguments:
  #   basePackages — function (self -> { package1 = ...; package2 = ...; })
  #   overlays     — list of overlay functions
  #
  # Returns the final package set with cluster-level operations.
  mkCluster =
    {
      basePackages,
      overlays ? [ ],
    }:
    let
      pkgs = applyOverlays overlays basePackages;

      allClosures = lib.concatMap (pkg: pkg.closure) (
        builtins.attrValues (
          lib.filterAttrs (_: v: builtins.isAttrs v && (v._type or "") == "k8s-package") pkgs
        )
      );

      # Deduplicate by resource identity.
      dedup =
        resources:
        let
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
                ns = if head.namespace or null == null then "_cluster_" else head.namespace;
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
                  queue = rest;
                };
        in
        go {
          seen = { };
          order = [ ];
          queue = resources;
        };

      allResources = dedup allClosures;
    in
    pkgs
    // {
      _type = "k8s-cluster";

      # All packages in the cluster.
      packages = lib.filterAttrs (_: v: builtins.isAttrs v && (v._type or "") == "k8s-package") pkgs;

      # All manifests from all packages (union of closures, deduplicated).
      manifests = allResources;

      # Cluster-level DAG as Graphviz DOT.
      # Renders ALL resources across ALL packages with their dependency edges.
      # Solid blue = deps (automatic, from refs), dashed red = requires (manual, inverted).
      dagDot = clusterToDot allResources;

      # Cluster-level DAG as human-readable tree (for terminal output).
      dagTree = clusterToTree allResources;
    };

  # Renders a DOT string for an arbitrary list of resources.
  # Useful outside mkCluster (e.g., for a subset of packages).
  clusterToDot =
    resources:
    let
      nodeLines = map (r: ''${dotId r} [label="${dotLabel r}"];'') resources;
      edgeLines = lib.concatMap (
        r:
        (map (d: "${dotId r} -> ${dotId d} [style=solid, color=blue];") r.deps)
        ++ (map (d: "${dotId r} -> ${dotId d} [style=dashed, color=red];") (r.requires or [ ]))
      ) resources;
    in
    ''
      digraph cluster {
        rankdir=TB;
        node [shape=box, style=rounded, fontname="monospace", fontsize=10];
        edge [fontsize=8];
      ${builtins.concatStringsSep "\n" nodeLines}
      ${builtins.concatStringsSep "\n" edgeLines}
      }
    '';

  # Renders a human-readable tree for an arbitrary list of resources.
  clusterToTree =
    resources:
    let
      renderResource =
        r:
        let
          depLines = map (d: "  dep-> ${resourceId d}") r.deps;
          reqLines = map (d: "  req-> ${resourceId d}") (r.requires or [ ]);
          lines = [ (resourceId r) ] ++ depLines ++ reqLines;
        in
        builtins.concatStringsSep "\n" lines;
    in
    builtins.concatStringsSep "\n\n" (map renderResource resources) + "\n";

}
