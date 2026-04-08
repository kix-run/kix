# Package view — consumer-facing shape of an evaluated instance.

{ lib, helpers }:

let
  inherit (helpers) mergeCollide collectTypedAttrs knownFolders;
in

{
  # Build the consumer-facing view of a package instance.
  #
  # Three layers, all merged with collision detection:
  #   1. folders  — plain attrsets from parts (no _type), excluding "root"
  #   2. autoKeys — auto-copied from root.out (fqdn, name, selector, etc.)
  #   3. system   — evaluator plumbing (_type, _meta, root, out, raw)
  #
  # Root-level resources (typed values) live only in raw, not on the surface.
  mkPackageView =
    {
      parts,
      rootOut,
      instanceName,
      packageInstance,
      packageMeta,
      namespaceName,
      aliases,
      # Evaluated config for this instance — exposed via _meta so the
      # cluster fixpoint can resolve function-shaped dep config injections
      # against the consumer's own config (e.g. stackgres-database
      # forwarding its `extensions` list into postgres).
      evaluatedConfig ? { },
    }:
    let
      ctx = "instance '${instanceName}'";

      # Layer 1: folders — only plain attrsets (no _type), excluding "root"
      folders = lib.filterAttrs (
        n: v: n != "root" && v != null && builtins.isAttrs v && !(v ? _type)
      ) parts;

      # Layer 2: auto-copied root.out (fqdn, name, selector, etc.)
      autoKeys = rootOut;

      # Layer 3: system/evaluator plumbing
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
          # The instance's fully-resolved config (option defaults +
          # cluster overrides + dep config injections). Read by
          # cluster.nix when resolving function-shaped injections
          # contributed by THIS instance into one of its deps.
          config = evaluatedConfig;
        };
      };

      # Known-folder structure check: resource directly on a known folder key → error
      _folderStructureChecks = builtins.foldl' (
        acc: folderName:
        let
          v = parts.${folderName} or null;
        in
        if v != null && builtins.isAttrs v && v ? _type then
          throw "${ctx}: '${folderName}' must be an attrset of resources, not a resource directly. Use '${folderName}.someName = ...' instead."
        else
          acc
      ) null (builtins.attrNames knownFolders);

      # Known-folder content warnings: wrong _type inside a known folder → trace warning
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
          builtins.trace "warning: ${ctx}.${folderName} contains ${r.kind or "?"}/${r.name or "?"} — unexpected _type '${r._type or "unknown"}'" inner
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
