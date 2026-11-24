{ lib, helpers }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail;
  inherit (helpers) mergeCollide knownFolders;
in

{
  mkPackageView =
    {
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
      ctx = "instance '${instanceName}'";

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
            instance = "${namespaceName}/${instanceName}";
            message = "'${folderName}' is a resource directly instead of an attribute set of resources.";
            fix = "Use '${folderName}.someName = ...' instead.";
          }
        else
          acc
      ) null (builtins.attrNames knownFolders);
    in
    builtins.seq _folderStructureChecks (
      mergeCollide "${ctx}: folder key collides with root.out" folders autoKeys
      |> mergeCollide "${ctx}: package key collides with system key" system
    );
}
