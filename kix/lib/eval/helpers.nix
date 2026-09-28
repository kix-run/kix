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

  # The resources an instance renders from its parts, without its
  # PackageInstance and hook resources. A managed instance keeps its parts
  # under `raw`; its top-level keys are the package's `out` interface, which
  # holds only the resources the package exports. `root` is excluded because
  # it repeats a resource held under a named part.
  instancePartResources =
    inst:
    let
      raw =
        inst.raw or (removeAttrs inst [
          "_type"
          "_meta"
          "_packageInstance"
          "_diagnostics"
          "_scorecardFindings"
          "_isImport"
          "root"
          "fqdn"
          "out"
          "overrideParts"
        ]);
    in
    builtins.filter (v: (v._type or "") == "k8s-resource") (
      collectTypedAttrs {
        excludeKeys = [
          "root"
          "meta"
        ];
      } raw
    );

  knownFolders = {
    secrets = {
      expectedTypes = [ "k8s-resource" ];
    };
    crds = {
      expectedTypes = [ "k8s-resource" ];
    };
  };
}
