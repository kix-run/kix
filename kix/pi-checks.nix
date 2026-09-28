# PI wiring invariant checks — eval-time assertions for the PackageInstance
# overlay design (see v2_discussions/24_package_instance_wiring.md).
#
# Validates 5 invariants:
# 1. No resource depends on a PI (subsumes invariant 2: cross-package edges are resource→resource)
# 3. PI references resources via annotation string context
# 4. PI's store closure covers all non-orphaned package resources
# 5. Activation only references PIs

{ lib }:

let
  helpers = import ./lib/eval/helpers.nix { inherit lib; };
in
rec {

  # --- Helpers ---

  # Strip string context from a store path.
  plainPath = resource: builtins.unsafeDiscardStringContext resource.outPath;

  # All store paths referenced in a resource's manifest (via string context).
  manifestCtxPaths =
    resource: builtins.attrNames (builtins.getContext (builtins.toJSON resource.rawManifest));

  # All store paths from requires + extraDeps (structural deps).
  reqDepPaths =
    resource:
    map (d: builtins.unsafeDiscardStringContext d.outPath) (
      builtins.filter (d: builtins.isAttrs d && d ? outPath) (
        (resource.requires or [ ]) ++ (resource.extraDeps or [ ])
      )
    );

  # All direct dependency store paths of a resource.
  allDepPaths = resource: manifestCtxPaths resource ++ reqDepPaths resource;

  # Flatten clusterInstances { nsName.instName = inst } → [ inst ... ]
  flattenInstances =
    clusterInstances:
    builtins.concatMap (
      nsName:
      map (instName: clusterInstances.${nsName}.${instName}) (
        builtins.attrNames clusterInstances.${nsName}
      )
    ) (builtins.attrNames clusterInstances);

  # Non-PI resources of an instance: the part set `collectResources` in
  # eval/cluster.nix renders, without the PI and hook resources.
  collectInstanceResources = helpers.instancePartResources;

  # All non-PI resource store paths for an instance, deduplicated.
  instanceResourcePaths =
    inst:
    let
      piPath = plainPath inst._packageInstance;
    in
    builtins.attrNames (
      builtins.listToAttrs (
        builtins.filter (e: e.name != piPath) (
          map (r: {
            name = plainPath r;
            value = true;
          }) (collectInstanceResources inst)
        )
      )
    );

  # Build a registry mapping plain store paths → resources from a list of resources.
  buildResourceRegistry =
    resources:
    builtins.listToAttrs (
      map (r: {
        name = plainPath r;
        value = r;
      }) resources
    );

  # --- Invariant 1: No resource depends on a PI ---
  #
  # `piPathMap` must hold managed instances only. An import renders nothing
  # but its marker PackageInstance, so a resource ordered after an import
  # (for example a workload after an imported DNS provider) depends on that
  # marker the same way it depends on a mkSecretRef marker.

  checkNoResourceDependsOnPI =
    clusterName: instances: piPathMap:
    let
      nonImports = builtins.filter (i: !(i._isImport or false)) instances;

      violations = builtins.concatMap (
        inst:
        let
          resources = collectInstanceResources inst;
          instName = inst._meta.instanceName;
        in
        builtins.concatMap (
          r:
          let
            deps = allDepPaths r;
            piDeps = builtins.filter (p: piPathMap ? ${p}) deps;
          in
          map (p: {
            resource = "${r.kind}/${r.name}";
            instance = instName;
            piInstance = piPathMap.${p};
          }) piDeps
        ) resources
      ) nonImports;
    in
    if violations == [ ] then
      true
    else
      let
        msgs = map (
          v:
          "'${v.resource}' in instance '${v.instance}' depends on the PackageInstance record for '${v.piInstance}'"
        ) violations;
      in
      throw "cluster '${clusterName}' has invalid package dependencies: resources must depend on the resources they use, not PackageInstance records: ${lib.concatStringsSep "; " msgs}";

  # --- Invariant 3: PI references resources via annotation string context ---

  checkPIReferencesResources =
    clusterName: instances:
    let
      nonImports = builtins.filter (i: !(i._isImport or false)) instances;

      violations = builtins.concatMap (
        inst:
        let
          pi = inst._packageInstance;
          instName = inst._meta.instanceName;
          resPaths = instanceResourcePaths inst;
          resPathSet = builtins.listToAttrs (
            map (p: {
              name = p;
              value = true;
            }) resPaths
          );
          piCtx = manifestCtxPaths pi;
          referencesAnyResource = builtins.any (p: resPathSet ? ${p}) piCtx;
        in
        if referencesAnyResource then [ ] else [ { instance = instName; } ]
      ) nonImports;
    in
    if violations == [ ] then
      true
    else
      let
        msgs = map (
          v: "PackageInstance '${v.instance}' does not reference any of its own resources"
        ) violations;
      in
      throw "cluster '${clusterName}' has invalid package dependencies: package resource references are missing: ${lib.concatStringsSep "; " msgs}";

  # --- Invariant 4: PI closure covers all non-orphaned package resources ---

  checkPIClosureComplete =
    clusterName: instances: clusterRegistry:
    let
      nonImports = builtins.filter (i: !(i._isImport or false)) instances;

      # BFS from a root resource through manifest context + requires edges,
      # restricted to paths known in the registry.
      transitiveReachable =
        root:
        let
          go =
            { seen, queue }:
            if queue == [ ] then
              seen
            else
              let
                head = builtins.head queue;
                rest = builtins.tail queue;
              in
              if seen ? ${head} then
                go {
                  inherit seen;
                  queue = rest;
                }
              else
                let
                  resource = clusterRegistry.${head} or null;
                  newPaths =
                    if resource == null then
                      [ ]
                    else
                      builtins.filter (p: clusterRegistry ? ${p} && !(seen ? ${p})) (allDepPaths resource);
                in
                go {
                  seen = seen // {
                    ${head} = true;
                  };
                  queue = rest ++ newPaths;
                };
        in
        go {
          seen = { };
          queue = [ (plainPath root) ];
        };

      violations = builtins.concatMap (
        inst:
        let
          pi = inst._packageInstance;
          instName = inst._meta.instanceName;
          resPaths = instanceResourcePaths inst;

          reachable = transitiveReachable pi;
          unreached = builtins.filter (p: !(reachable ? ${p})) resPaths;
          unreachedResources = map (p: clusterRegistry.${p}) unreached;
        in
        map (r: {
          resource = "${r.kind}/${r.name}";
          instance = instName;
        }) unreachedResources
      ) nonImports;
    in
    if violations == [ ] then
      true
    else
      let
        msgs = map (
          v: "'${v.resource}' in '${v.instance}' is not referenced by its PackageInstance or its dependencies"
        ) violations;
      in
      throw "cluster '${clusterName}' has invalid package dependencies: package dependencies do not include all resources: ${lib.concatStringsSep "; " msgs}";

  # --- Invariant 5: Activation only references PIs ---

  checkActivationOnlyReferencesPIs =
    clusterName: activation: piPathMap: clusterRegistry:
    let
      actCtx = manifestCtxPaths activation;
      # Filter to paths that are known resources (ignore non-resource store paths
      # like the toFile paths from Nix internals).
      resourceCtxPaths = builtins.filter (p: clusterRegistry ? ${p}) actCtx;
      nonPIPaths = builtins.filter (p: !(piPathMap ? ${p})) resourceCtxPaths;
      nonPIResources = map (p: clusterRegistry.${p}) nonPIPaths;
    in
    if nonPIPaths == [ ] then
      true
    else
      let
        msgs = map (
          r: "'${r.kind}/${r.name}' is referenced by Activation but is not a PackageInstance"
        ) nonPIResources;
      in
      throw "cluster '${clusterName}' has invalid package dependencies: Activation must reference PackageInstance records: ${lib.concatStringsSep "; " msgs}";

  # --- Top-level validator ---

  validatePIWiring =
    clusterName: cluster:
    let
      instances = flattenInstances cluster.clusterInstances;

      # Build PI path set: { piStorePath = instanceName; ... }
      piPathMap = builtins.listToAttrs (
        map (inst: {
          name = plainPath inst._packageInstance;
          value = inst._meta.instanceName;
        }) instances
      );
      managedPiPathMap = removeAttrs piPathMap (
        map (inst: plainPath inst._packageInstance) (
          builtins.filter (inst: inst._isImport or false) instances
        )
      );

      # Build cluster-wide registry: { storePath = resource; ... }
      allResources = builtins.concatMap (
        inst:
        let
          resources = collectInstanceResources inst;
        in
        resources ++ [ inst._packageInstance ]
      ) instances;

      clusterRegistry = buildResourceRegistry allResources;

      inv1 = checkNoResourceDependsOnPI clusterName instances managedPiPathMap;
      inv3 = checkPIReferencesResources clusterName instances;
      inv4 = checkPIClosureComplete clusterName instances clusterRegistry;
      inv5 = checkActivationOnlyReferencesPIs clusterName cluster.activation piPathMap clusterRegistry;
    in
    builtins.seq inv1 (builtins.seq inv3 (builtins.seq inv4 (builtins.seq inv5 true)));
}
