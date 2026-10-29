# Audit scope-time vs instance-level network policy edge extraction.
#
# Compares, per instance, per cluster:
#   A = inst._networkEdges           (processInstance, post-fixpoint, sees allPartResources ++ depResources)
#   B = ∪ w._generatedNetpolEdges    (buildWorkloadCnps, scope-time, sees only depResourcesForNetpol)
#
# An edge in A but not in B = an edge that today's cluster-level
# generateIngressPolicies catches but scope-time extraction would miss.
# Deleting generateIngressPolicies makes every such edge a silent
# netpol regression.
#
# Empty `missingFromScope` across every instance in every fixture cluster
# is the green light to delete generateIngressPolicies.
#
# Usage:
#   nix eval --impure --json \
#     --extra-experimental-features 'pipe-operators flakes nix-command' \
#     -f scripts/netpol-edge-audit.nix \
#     > /tmp/netpol-audit.json
#   python3 scripts/netpol-edge-audit.py /tmp/netpol-audit.json
#
# The eval is pure-ish (pulls `currentSystem` via --impure) and does NOT
# touch netpol.nix, so it's safe to run while someone else is editing that
# file.

let
  flake = builtins.getFlake (toString ./..);
  system = builtins.currentSystem;
  # Hard-skip clusters known to fail eval for reasons unrelated to netpol.
  # example-import uses `postgres.raw.cluster` which isn't a real attr.
  skipClusters = [ "example-import" ];
  allClusters = flake.legacyPackages.${system}.kixClusters;
  clusters = builtins.removeAttrs allClusters skipClusters;

  isResource = v: builtins.isAttrs v && (v._type or "") == "k8s-resource";
  workloadKinds = [
    "Deployment"
    "StatefulSet"
    "DaemonSet"
  ];
  isWorkload = r: isResource r && builtins.elem (r.kind or "") workloadKinds;

  # Walk an instance's raw parts attrset collecting all workload resources.
  # `raw` is view.nix's pass-through of the package's `parts`, which may
  # nest arbitrarily, so recurse on attrs until we hit a resource.
  collectWorkloads =
    root:
    let
      go =
        v:
        if isResource v then
          (if isWorkload v then [ v ] else [ ])
        else if builtins.isAttrs v then
          builtins.concatMap go (builtins.attrValues v)
        else if builtins.isList v then
          builtins.concatMap go v
        else
          [ ];
    in
    go root;

  # Build a canonical edge key that is computable from both sides identically.
  # Shape matches the records built in netpol.nix's extractServiceEdges*
  # (sourceSelector, sourceNamespace, service, targetSelector, targetNamespace, and ports).
  edgeKey =
    e:
    let
      svcPath = builtins.unsafeDiscardStringContext (toString e.service.outPath);
      srcSel = builtins.toJSON (e.sourceSelector or { });
    in
    "${e.sourceNamespace or "?"}|${srcSel}|${e.targetNamespace or "?"}|${svcPath}";

  describeEdge = e: {
    sourceNamespace = e.sourceNamespace or null;
    sourceSelector = e.sourceSelector or { };
    targetNamespace = e.targetNamespace or null;
    targetService = e.service.name or null;
    targetServicePath = builtins.unsafeDiscardStringContext (toString e.service.outPath);
    targetSelector = e.targetSelector or { };
  };

  uniq =
    xs:
    let
      go =
        { seen, out }:
        x:
        let
          k = edgeKey x;
        in
        if seen ? ${k} then
          { inherit seen out; }
        else
          {
            seen = seen // {
              ${k} = true;
            };
            out = out ++ [ x ];
          };
    in
    (builtins.foldl' go {
      seen = { };
      out = [ ];
    } xs).out;

  auditInstance =
    instName: inst:
    let
      groundEdges = uniq (inst._networkEdges or [ ]);
      workloads = collectWorkloads (inst.raw or { });
      scopeEdges = uniq (builtins.concatMap (w: w._generatedNetpolEdges or [ ]) workloads);

      scopeKeySet = builtins.listToAttrs (
        map (e: {
          name = edgeKey e;
          value = true;
        }) scopeEdges
      );
      groundKeySet = builtins.listToAttrs (
        map (e: {
          name = edgeKey e;
          value = true;
        }) groundEdges
      );

      missingFromScope = builtins.filter (e: !(scopeKeySet ? ${edgeKey e})) groundEdges;
      extraInScope = builtins.filter (e: !(groundKeySet ? ${edgeKey e})) scopeEdges;
    in
    {
      inherit instName;
      groundCount = builtins.length groundEdges;
      scopeCount = builtins.length scopeEdges;
      workloadCount = builtins.length workloads;
      missingFromScope = map describeEdge missingFromScope;
      extraInScope = map describeEdge extraInScope;
    };

  auditCluster =
    clusterName: cluster:
    let
      nsMap = cluster.clusterInstances or { };
      perNs = builtins.concatMap (
        nsName:
        let
          instMap = nsMap.${nsName};
        in
        map (instName: auditInstance "${nsName}/${instName}" instMap.${instName}) (
          builtins.attrNames instMap
        )
      ) (builtins.attrNames nsMap);
    in
    {
      cluster = clusterName;
      instances = perNs;
      totalMissing = builtins.foldl' (a: i: a + builtins.length i.missingFromScope) 0 perNs;
      totalExtra = builtins.foldl' (a: i: a + builtins.length i.extraInScope) 0 perNs;
    };

  safeAudit =
    clusterName: cluster:
    let
      result = auditCluster clusterName cluster;
      # tryEval only catches WHNF failures; force the whole tree first so
      # nested eval errors (e.g. broken fixtures) get turned into a skip.
      r = builtins.tryEval (builtins.deepSeq result result);
    in
    if r.success then
      r.value
    else
      {
        cluster = clusterName;
        error = "evaluation failed (skipped)";
        instances = [ ];
        totalMissing = 0;
        totalExtra = 0;
      };

in
builtins.mapAttrs safeAudit clusters
