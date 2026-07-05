# v2 fragment composition — mergeFragments.
#
# Each team produces a fragment { namespaces, instances }.
# mergeFragments combines them with collision detection.

{ lib }:

rec {

  # Deep merge a list of namespace config attrsets. Named network policies
  # merge naturally. Leaf-field conflicts (same key, non-attrset value in
  # more than one input) throw an error.
  deepMergeNs =
    attrsList:
    builtins.zipAttrsWith (
      k: values:
      if builtins.length values == 1 then
        builtins.head values
      else if builtins.all builtins.isAttrs values then
        deepMergeNs values
      else
        throw "namespace policy conflict on key '${k}': multiple fragments define a leaf value"
    ) attrsList;

  # Merge multiple fragments into a single { namespaces, instances } for buildCluster.
  #
  # Instance collision: same (namespace, instance) from different fragments = error.
  # Namespace collision: deep merge (leaf-field conflicts error).
  mergeFragments =
    {
      fragments,
      namespacePolicies ? { },
    }:
    {
      # Deep merge namespace configs, then layer platform-owned policies on top.
      namespaces = deepMergeNs [
        (deepMergeNs (map (f: f.namespaces or { }) fragments))
        namespacePolicies
      ];

      # Instance sets are per-namespace attrsets; collisions on the inner
      # (namespace, instance) key are errors.
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
              throw "instance collision in namespace '${nsName}': '${instName}' defined by multiple fragments"
            else
              builtins.head defs
          ) nsInstanceSets
        ) allInstanceSets;
    };

}
