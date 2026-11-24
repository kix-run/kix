{ lib, helpers }:

let
  inherit (helpers) mergeCollide knownFolders;
in

{
  # Build the view other instances read of an instance. `fail` is the
  # instance's `scope.fail`, which names it and its package in an error.
  mkPackageView =
    {
      fail,
      parts,
      rootOut,
      instanceName,
      packageInstance,
      packageMeta,
      namespaceName,
      aliases,
      version ? null,
      evaluatedConfig ? { },
    }:
    let
      # Omit known folders (`crds`, `secrets`) that `rootOut` also defines so
      # `rootOut` takes precedence in the package view without triggering a
      # collision. The folder's resources are still emitted because emission
      # reads `parts` directly.
      folders = lib.filterAttrs (
        n: v:
        n != "root"
        && v != null
        && builtins.isAttrs v
        && !(v ? _type)
        && !(knownFolders ? ${n} && rootOut ? ${n})
      ) parts;

      autoKeys = rootOut;

      system = {
        _type = "k8s-instance";
        _packageInstance = packageInstance;
        root = packageInstance;
        out = rootOut;
        raw = parts;
        _meta = {
          inherit
            instanceName
            namespaceName
            aliases
            packageMeta
            version
            ;
          namespace = namespaceName;
          config = evaluatedConfig;
        };
      };

      _folderStructureChecks = builtins.foldl' (
        acc: folderName:
        let
          v = parts.${folderName} or null;
        in
        if v != null && builtins.isAttrs v && v ? _type then
          fail {
            message = "'${folderName}' is a resource directly instead of an attribute set of resources.";
            fix = "Use '${folderName}.someName = ...' instead.";
          }
        else
          acc
      ) null (builtins.attrNames knownFolders);
    in
    builtins.seq _folderStructureChecks (
      mergeCollide {
        inherit fail;
        error = names: {
          message = "Both `build` (as a part group) and `root.out` define ${names}, which collide because Kix exposes both on the instance.";
          fix = "Rename ${names} in `build` or in `root.out`.";
        };
      } folders autoKeys
      |> mergeCollide {
        inherit fail;
        error = names: {
          message = "`build` or `root.out` defines ${names}, which is reserved by Kix on every instance.";
          fix = "Rename ${names} in `build` or `root.out`. Reserved instance attributes: ${lib.concatStringsSep ", " (builtins.attrNames system)}.";
        };
      } system
    );
}
