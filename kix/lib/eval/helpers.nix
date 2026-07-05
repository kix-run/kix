{ lib }:

rec {
  mergeCollide =
    context: a: b:
    let
      collisions = builtins.intersectAttrs a b;
    in
    if collisions == { } then
      a // b
    else
      throw "${context}: key collision on ${builtins.concatStringsSep ", " (builtins.attrNames collisions)}";

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

  knownFolders = {
    secrets = {
      expectedTypes = [ "k8s-resource" ];
    };
    crds = {
      expectedTypes = [ "k8s-resource" ];
    };
  };
}
