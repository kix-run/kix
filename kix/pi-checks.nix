# PI wiring invariant checks — eval-time assertions for the PackageInstance
# overlay design (see v2_discussions/24_package_instance_wiring.md).
#
# Validates 5 invariants:
# 1. No resource depends on a PI (subsumes invariant 2: cross-package edges are resource→resource)
# 3. PI references resources via annotation string context
# 4. PI's store closure covers all non-orphaned package resources
# 5. Activation only references PIs

{ lib }:

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

  # Collect non-PI resources from an instance (mirrors collectResources minus PI).
  # Also extracts the main resource path from inst.out context, since packages
  # with only a main resource (e.g. PVC) have their main overridden by the PI
  # and it won't appear in parts.
  collectInstanceResources =
    inst:
    let
      parts = removeAttrs inst [
        "_type"
        "_meta"
        "_packageInstance"
        "_isImport"
        "main"
        "fqdn"
        "out"
        "overrideParts"
      ];
      partResources = builtins.filter (
        v: v != null && builtins.isAttrs v && (v._type or "") == "k8s-resource"
      ) (builtins.attrValues parts);
    in
    partResources;

  # Store paths of the main resource(s) referenced by inst.out.
  # inst.out carries the main resource's context (not the PI's),
  # so extracting context from out.name gives the main resource path.
  mainResourcePaths =
    inst:
    let
      outName = inst.out.name or "";
      ctx = if outName == "" then { } else builtins.getContext outName;
    in
    builtins.attrNames ctx;

  # All non-PI resource store paths for an instance: parts + main resource path.
  instanceResourcePaths =
    inst:
    let
      piPath = plainPath inst._packageInstance;
      partPaths = map plainPath (collectInstanceResources inst);
      mainPaths = mainResourcePaths inst;
      allPaths = partPaths ++ mainPaths;
    in
    # Deduplicate and exclude the PI path
    builtins.attrNames (
      builtins.listToAttrs (
        builtins.filter (e: e.name != piPath) (
          map (p: {
            name = p;
            value = true;
          }) allPaths
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
          v: "'${v.resource}' in instance '${v.instance}' depends on PI of '${v.piInstance}'"
        ) violations;
      in
      throw "validatePIWiring(${clusterName}): Invariant 1 violated — resources depend on PIs: ${lib.concatStringsSep "; " msgs}";

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
        msgs = map (v: "PI of '${v.instance}' does not reference any of its own resources") violations;
      in
      throw "validatePIWiring(${clusterName}): Invariant 3 violated — ${lib.concatStringsSep "; " msgs}";

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
          # Only report resources in the registry (main resource path may not be)
          unreachedInRegistry = builtins.filter (p: clusterRegistry ? ${p}) unreached;
          unreachedResources = map (p: clusterRegistry.${p}) unreachedInRegistry;
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
        msgs = map (v: "'${v.resource}' in '${v.instance}' not reachable from its PI") violations;
      in
      throw "validatePIWiring(${clusterName}): Invariant 4 violated — resources not in PI closure: ${lib.concatStringsSep "; " msgs}";

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
        msgs = map (r: "'${r.kind}/${r.name}' is referenced by Activation but is not a PI") nonPIResources;
      in
      throw "validatePIWiring(${clusterName}): Invariant 5 violated — Activation references non-PI resources: ${lib.concatStringsSep "; " msgs}";

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

      # Build cluster-wide registry: { storePath = resource; ... }
      allResources = builtins.concatMap (
        inst:
        let
          resources = collectInstanceResources inst;
        in
        resources ++ [ inst._packageInstance ]
      ) instances;

      clusterRegistry = buildResourceRegistry allResources;

      inv1 = checkNoResourceDependsOnPI clusterName instances piPathMap;
      inv3 = checkPIReferencesResources clusterName instances;
      inv4 = checkPIClosureComplete clusterName instances clusterRegistry;
      inv5 = checkActivationOnlyReferencesPIs clusterName cluster.activation piPathMap clusterRegistry;
    in
    builtins.seq inv1 (builtins.seq inv3 (builtins.seq inv4 (builtins.seq inv5 true)));
}
