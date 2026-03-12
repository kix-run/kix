# Transitive closure computation over the resource dependency graph.
#
# Follows both:
# - deps (from refs, automatic — "I reference this resource by name in my spec")
# - requires (manual, inverted — "I need this to function, but it references me")
#
# The closure is the set of all resources transitively needed to deploy a
# given root resource. This is the core operation — resource.closure gives you
# every resource needed, discovered through both reference tracking and manual
# requires annotations.

{ lib }:

rec {

  # Computes the transitive closure starting from a root resource.
  #
  # Returns a list of resources in BFS order (closest dependencies first).
  # Each resource appears at most once (deduplicated by identity key).
  #
  # Identity key: "kind/name@namespace" — must be unique per resource.
  # If two distinct resources share an identity, they'll be deduplicated
  # (which is a bug in the package, not in the closure algorithm).
  computeClosure =
    root:
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
              queue = rest ++ head.deps ++ (head.requires or [ ]);
            };
    in
    go {
      seen = { };
      order = [ ];
      queue = [ root ];
    };

  # Extracts just the manifests from a closure (for serialization).
  closureManifests = root: map (r: r.manifest) (computeClosure root);

  # Validates that a closure has no identity conflicts.
  # Returns the closure if valid, throws on conflict.
  validateClosure =
    closure:
    let
      ids = map (r: "${r.kind}/${r.name}@${r.namespace}") closure;
      # Check for duplicates by comparing length of unique list
      unique = lib.unique ids;
    in
    assert
      (builtins.length unique == builtins.length ids)
      || throw "Closure contains duplicate resource identities: ${builtins.toJSON (lib.subtractLists unique ids)}";
    closure;

  # Renders a closure as a Graphviz DOT digraph.
  #
  # Solid arrows = deps (automatic, from refs in spec)
  # Dashed arrows = requires (manual, inverted relationships)
  #
  # Usage:
  #   nix eval --raw --impure --expr '...' | dot -Tsvg -o dag.svg
  #   nix eval --raw --impure --expr '...' | dot -Tpng -o dag.png
  closureToDot =
    root:
    let
      closure' = computeClosure root;
      resourceId =
        r:
        let
          ns = if r.namespace or null == null then "cluster" else r.namespace;
        in
        "${r.kind}/${r.name}@${ns}";
      # Sanitize for DOT node IDs (replace special chars)
      dotId = r: builtins.replaceStrings [ "/" "@" "-" ":" "." ] [ "_" "_" "_" "_" "_" ] (resourceId r);
      dotLabel = r: "${r.kind}\\n${r.name}";

      nodeLines = map (r: ''${dotId r} [label="${dotLabel r}"];'') closure';

      edgeLines = lib.concatMap (
        r:
        (map (d: "${dotId r} -> ${dotId d} [style=solid, color=blue];") r.deps)
        ++ (map (d: "${dotId r} -> ${dotId d} [style=dashed, color=red];") (r.requires or [ ]))
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

  # Renders a closure as a human-readable tree string (for terminal output).
  #
  # Shows each resource with its deps and requires indented below.
  closureToTree =
    root:
    let
      closure' = computeClosure root;
      resourceId =
        r:
        let
          ns = if r.namespace or null == null then "cluster" else r.namespace;
        in
        "${r.kind}/${r.name}@${ns}";

      renderResource =
        r:
        let
          depLines = map (d: "  dep-> ${resourceId d}") r.deps;
          reqLines = map (d: "  req-> ${resourceId d}") (r.requires or [ ]);
          lines = [ (resourceId r) ] ++ depLines ++ reqLines;
        in
        builtins.concatStringsSep "\n" lines;
    in
    builtins.concatStringsSep "\n\n" (map renderResource closure') + "\n";

}
