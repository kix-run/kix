{ lib, helpers }:

let
  inherit (helpers) mergeCollide collectTypedAttrs knownFolders;
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
          throw "${ctx}: '${folderName}' must be an attribute set of resources, not a resource directly. Use '${folderName}.someName = ...' instead."
        else
          acc
      ) null (builtins.attrNames knownFolders);

      _folderContentChecks = builtins.foldl' (
        acc: folderName:
        let
          spec = knownFolders.${folderName};
          contents = parts.${folderName} or { };
          typed = collectTypedAttrs { } contents;
          bad = builtins.filter (r: !(builtins.elem (r._type or "") spec.expectedTypes)) typed;
        in
        lib.foldl' (
          inner: r:
          builtins.trace "warning: ${ctx}.${folderName} contains ${r.kind or "?"}/${r.name or "?"}; unexpected _type '${r._type or "unknown"}'" inner
        ) acc bad
      ) null (builtins.attrNames knownFolders);

    in
    builtins.seq _folderStructureChecks (
      builtins.seq _folderContentChecks (
        mergeCollide "${ctx}: folder key collides with root.out" folders autoKeys
        |> mergeCollide "${ctx}: package key collides with system key" system
      )
    );
}
