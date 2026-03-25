# Shared helpers: collision-checking merge, typed-attr collector, known folders.

{ lib }:

rec {
  # Merge two attrsets, throwing on key collision.
  mergeCollide =
    context: a: b:
    let
      collisions = builtins.intersectAttrs a b;
    in
    if collisions == { } then
      a // b
    else
      throw "${context}: key collision on ${builtins.concatStringsSep ", " (builtins.attrNames collisions)}";

  # Collect all typed objects (anything with _type) from nested attrsets,
  # up to maxDepth levels deep. Stops at _type boundaries — never descends
  # into typed objects. Plain attrsets without _type are treated as folders.
  collectTypedAttrs =
    {
      excludeKeys ? [ ],
      maxDepth ? 3,
    }:
    attrs:
    let
      go =
        depth: a:
        builtins.concatMap (
          n:
          let
            v = a.${n};
          in
          if v == null then
            [ ]
          else if !(builtins.isAttrs v) then
            [ ]
          else if v ? _type then
            [ v ]
          else if depth >= maxDepth then
            [ ]
          else
            go (depth + 1) v
        ) (builtins.attrNames (removeAttrs a excludeKeys));
    in
    go 0 attrs;

  # Well-known folders that get content-type validation warnings.
  knownFolders = {
    secrets = {
      expectedTypes = [ "k8s-resource" ];
    };
    crds = {
      expectedTypes = [
        "k8s-resource"
        "crd-ref"
      ];
    };
  };
}
