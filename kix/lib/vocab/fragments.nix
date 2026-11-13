{ lib }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail;
in
rec {

  deepMergeNs =
    attrsList:
    builtins.zipAttrsWith (
      k: values:
      if builtins.length values == 1 then
        builtins.head values
      else if builtins.all builtins.isAttrs values then
        deepMergeNs values
      else
        fail "namespace policy conflict on key '${k}': multiple fragments define a leaf value"
    ) attrsList;

  mergeFragments =
    {
      fragments,
      namespacePolicies ? { },
    }:
    {
      namespaces = deepMergeNs [
        (deepMergeNs (map (f: f.namespaces or { }) fragments))
        namespacePolicies
      ];

      instances =
        args:
        let
          allInstanceSets = map (
            f:
            let
              v = f.instances or { };
            in
            if builtins.isFunction v then v args else v
          ) fragments;
        in
        builtins.zipAttrsWith (
          nsName: nsInstanceSets:
          builtins.zipAttrsWith (
            instName: defs:
            if builtins.length defs > 1 then
              fail "instance collision in namespace '${nsName}': '${instName}' defined by multiple fragments"
            else
              builtins.head defs
          ) nsInstanceSets
        ) allInstanceSets;
    };

}
