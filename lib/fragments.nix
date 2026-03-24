# v2 fragment composition — mergeFragments.
#
# Each team produces a fragment { namespaces, instances }.
# mergeFragments combines them with collision detection.

{ lib }:

rec {

  # Merge multiple fragments into a single { namespaces, instances } for buildCluster.
  #
  # Instance collision: same (namespace, instance) from different fragments = error.
  # Namespace collision: deep merge (leaf-field conflicts error).
  mergeFragments =
    {
      fragments,
      namespacePolicies ? { },
    }:
    let
      # Merge instances with collision checking
      mergedInstances =
        args:
        let
          allInstanceFns = map (
            f: if builtins.isFunction (f.instances or { }) then f.instances else (_: f.instances or { })
          ) fragments;

          # Evaluate all fragment instance functions
          allInstanceSets = map (fn: fn args) allInstanceFns;

          # Check for collisions and merge
          mergeTwo =
            a: b:
            let
              nsNames = lib.unique (builtins.attrNames a ++ builtins.attrNames b);
            in
            builtins.listToAttrs (
              map (
                nsName:
                let
                  aInsts = a.${nsName} or { };
                  bInsts = b.${nsName} or { };
                  collisions = builtins.filter (n: builtins.hasAttr n aInsts) (builtins.attrNames bInsts);
                in
                if collisions != [ ] then
                  throw "instance collision in namespace '${nsName}': ${builtins.toJSON collisions} defined by multiple fragments"
                else
                  {
                    name = nsName;
                    value = aInsts // bInsts;
                  }
              ) nsNames
            );
        in
        builtins.foldl' mergeTwo { } allInstanceSets;

      # Deep merge namespaces (leaf conflicts error)
      mergedNamespaces =
        let
          allNs = map (f: f.namespaces or { }) fragments;
          mergeNsTwo =
            a: b:
            let
              nsNames = lib.unique (builtins.attrNames a ++ builtins.attrNames b);
            in
            builtins.listToAttrs (
              map (nsName: {
                name = nsName;
                value = deepMergeNs (a.${nsName} or { }) (b.${nsName} or { });
              }) nsNames
            );
        in
        builtins.foldl' mergeNsTwo { } allNs;

      # Apply platform-owned policies on top
      finalNamespaces =
        let
          nsNames = lib.unique (builtins.attrNames mergedNamespaces ++ builtins.attrNames namespacePolicies);
        in
        builtins.listToAttrs (
          map (nsName: {
            name = nsName;
            value = deepMergeNs (mergedNamespaces.${nsName} or { }) (namespacePolicies.${nsName} or { });
          }) nsNames
        );

    in
    {
      namespaces = finalNamespaces;
      instances = mergedInstances;
    };

  # Deep merge two namespace configs. Named network policies merge naturally.
  # Leaf-field conflicts throw errors.
  deepMergeNs =
    a: b:
    let
      keys = lib.unique (builtins.attrNames a ++ builtins.attrNames b);
    in
    builtins.listToAttrs (
      map (
        k:
        let
          av = a.${k} or null;
          bv = b.${k} or null;
        in
        {
          name = k;
          value =
            if av == null then
              bv
            else if bv == null then
              av
            else if builtins.isAttrs av && builtins.isAttrs bv then
              deepMergeNs av bv
            else
              throw "namespace policy conflict on key '${k}': both fragments define a leaf value";
        }
      ) keys
    );

}
