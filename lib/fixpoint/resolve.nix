# Tree walker — automatic dependency collection from resource specs.
#
# This is the equivalent of what `builtins.derivation` does internally in Nix:
# walk all attribute values, find everything tagged as a ref, collect the
# source resources into the dependency list.
#
# The walker recurses into attrsets and lists, resolves refs to their plain
# values (for the final manifest), and accumulates the source resources (for
# the dependency list). mkResource calls this on spec/data/annotations and
# gets deps for free.
#
# Performance: runs during Nix evaluation (not at build time). Recursion depth
# matches spec depth, which is bounded by K8s resource structure.

{ lib, refs }:

let
  inherit (refs) isRef isTrackedStr;
in
rec {

  # Resolves a value, returning { resolved, deps }.
  #
  # - Refs → resolved to their plain value, resource collected as dep
  # - Tracked strings → parts concatenated, ref parts collected as deps
  # - Lists → recursed element-wise
  # - Attrsets → recursed value-wise (but k8s-resource attrsets are NOT
  #   recursed into — they may appear in `requires` lists, handled by
  #   computeClosure instead)
  # - Everything else → passed through unchanged
  resolve =
    val:
    if isRef val then
      {
        resolved = val.value;
        deps = [ val.resource ];
      }

    else if isTrackedStr val then
      let
        resolvePart =
          p:
          if isRef p then
            {
              s = toString p.value;
              deps = [ p.resource ];
            }
          else
            {
              s = toString p;
              deps = [ ];
            };
        parts = map resolvePart val.parts;
      in
      {
        resolved = builtins.concatStringsSep "" (map (p: p.s) parts);
        deps = builtins.concatLists (map (p: p.deps) parts);
      }

    else if builtins.isList val then
      let
        rs = map resolve val;
      in
      {
        resolved = map (r: r.resolved) rs;
        deps = builtins.concatLists (map (r: r.deps) rs);
      }

    else if builtins.isAttrs val then
      # Don't recurse into resources — they appear in `requires` lists and
      # are handled by computeClosure. Recursing into them would create
      # infinite loops (resource → spec → ref → resource → spec → ...).
      if (val._type or "") == "k8s-resource" then
        {
          resolved = val;
          deps = [ ];
        }
      # Don't recurse into explicit markers — these are for removeNulls and
      # should pass through unchanged.
      else if val ? __kixExplicit then
        {
          resolved = val;
          deps = [ ];
        }
      else
        let
          names = builtins.attrNames val;
          rs = lib.mapAttrs (_: resolve) val;
        in
        {
          resolved = lib.mapAttrs (_: r: r.resolved) rs;
          deps = builtins.concatLists (map (k: rs.${k}.deps) names);
        }

    else
      {
        resolved = val;
        deps = [ ];
      };

}
