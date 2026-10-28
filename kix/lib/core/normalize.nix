# Normalize Kubernetes manifests by dropping null values while preserving
# intentional empty attrsets and lists.
#
# Normalization runs bottom-up:
#   - Null values are removed.
#   - A non-empty attrset or list whose elements all normalize to null
#     collapses to null and is removed by its parent.
#   - An attrset or list written literally empty (`{ }` or `[ ]`) is kept.
#
# `keep` marks an attrset with `_kixKeep = true` so it normalizes to `{ }`
# instead of collapsing to null when all of its optional fields are null.
# Because `_kixKeep` is an attribute, it survives later attrset merges that
# add new null fields. Lists are replaced rather than merged, so `keep`
# normalizes lists immediately.
{ lib }:

rec {
  keepMarker = "_kixKeep";

  normalizeValue =
    v:
    if builtins.isAttrs v && !(lib.isDerivation v) then
      let
        kept = v ? ${keepMarker};
        bare = removeAttrs v [ keepMarker ];
        norm = lib.filterAttrs (_: x: x != null) (builtins.mapAttrs (_: normalizeValue) bare);
      in
      if bare == { } then
        { }
      else if norm == { } then
        (if kept then { } else null)
      else
        norm
    else if builtins.isList v then
      let
        norm = builtins.filter (x: x != null) (map normalizeValue v);
      in
      if v == [ ] then
        [ ]
      else if norm == [ ] then
        null
      else
        norm
    else
      v;

  # Normalize a manifest attrset, returning { } if the top level collapses to null.
  normalizeManifest =
    attrs:
    let
      n = normalizeValue attrs;
    in
    if n == null then { } else n;

  # Normalize `keep`-marked subtrees in place so `rawManifest` and its
  # identity JSON never contain `_kixKeep`. Unmarked subtrees retain their
  # nulls until final manifest rendering.
  resolveKeeps =
    v:
    if builtins.isAttrs v && !(lib.isDerivation v) then
      if v ? ${keepMarker} then
        let
          n = normalizeValue v;
        in
        if n == null then { } else n
      else
        builtins.mapAttrs (_: resolveKeeps) v
    else if builtins.isList v then
      map resolveKeeps v
    else
      v;

  # Mark an attrset or normalize a list so it renders as empty (`{ }` or `[ ]`)
  # rather than collapsing to null when all of its elements are null.
  keep =
    v:
    if builtins.isAttrs v then
      v // { ${keepMarker} = true; }
    else if builtins.isList v then
      (
        let
          n = normalizeValue v;
        in
        if n == null then [ ] else n
      )
    else
      throw "kix.keep: expected an attribute set or list, got ${builtins.typeOf v}";
}
