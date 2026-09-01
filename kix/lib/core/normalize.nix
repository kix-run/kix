# Collapse-rule manifest normalization (kixpkgs#9).
#
# Kubernetes assigns meaning to many empty values (`emptyDir: {}` selects
# the volume source; an empty label selector means "match everything";
# `subresources.status: {}` enables the subresource), so normalization must
# keep the empties an author wrote while removing the accidental ones
# (attrsets whose members are all null, the shape merged unset options
# produce).
#
# The collapse rule does that, bottom-up:
#   - nulls are dropped;
#   - a container that HAD members but lost all of them collapses to null
#     and is dropped by its parent in turn;
#   - a container written literally empty is kept.
#
# At normalization time the two cases are distinguishable: an accidental
# empty still holds its nulls, an intentional one holds nothing.
#
# `keep` covers the one gap: a constructor building a presence-meaningful
# container from optional arguments that may ALL be null. It marks the
# attrset with an additive `_kixKeep` key; normalization honors the marker
# (the container never collapses to absent) and strips it. The marker
# survives later merges that introduce fresh nulls, because merge functions
# union it in rather than replacing it. Lists need no marker: Nix merge
# functions replace lists wholesale, so a kept list cannot be re-filled
# with nulls after the fact, and `keep` normalizes them eagerly instead.
#
# Derivations pass through untouched. There is deliberately no field-name
# carve-out (CRD openAPIV3Schema subtrees are normalized like everything
# else): the collapse rule keeps literal empties on its own, so a schema
# needs no shield. The only value normalization can remove from a schema
# is an actual null (e.g. `default = null;`), which no in-tree CRD
# carries.
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

  # Normalize a whole manifest: the top level never collapses to null.
  normalizeManifest =
    attrs:
    let
      n = normalizeValue attrs;
    in
    if n == null then { } else n;

  # Resolve `keep`-marked subtrees in place, leaving everything else
  # untouched. Runs at the mkResource boundary so rawManifest (and the
  # identity JSON derived from it) never carries the marker, and so
  # rawManifest consumers (rules, netpol derivation, helm introspection)
  # see the container the way it will render. Unmarked values keep their
  # nulls here; final normalization handles those.
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

  # kix.keep — mark a container "never collapse to absent; render the empty
  # shell instead". For constructors of presence-meaningful fields
  # (emptyDir, selectors) built from optional arguments.
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
      throw "kix.keep: expected an attrset or list, got ${builtins.typeOf v}";
}
