# Single source of truth for the operator.victoriametrics.com CRD set.
# Consumed by crds.nix (CRD resources) and operator.nix (RBAC plurals),
# so the shipped CRDs and the operator's permissions cannot drift apart.
#
# RUNTIME INVARIANT (learned on kind, 2026-08-31): the operator requires
# its COMPLETE CRD bundle — slim-shipping a subset of the group is not an
# option, twice over:
#   1. At startup it unconditionally registers status-condition field
#      indexers for every kind in ChildConditionIndexedKinds
#      (k8stools/child_condition_index.go @ v0.74.1) and the manager
#      crashes immediately ("cannot register status condition indexers")
#      if any of those CRDs is absent.
#   2. It then starts informer watches for every controller; a watch on a
#      missing kind dies ~3 minutes in with "failed to wait for ... caches
#      to sync" (observed live with *v1.VLAgent) and takes the manager
#      down — a slow crashloop.
# So this table mirrors the chart's crd.yaml bundle for the pinned
# operator version (25 kinds @ 0.67.3 / v0.74.1), plurals verbatim —
# note the irregulars (vmanomalies, vmdistributed, vldistributed).
# crds.nix throws at eval time if the table stops covering
# `indexedKinds`, so a "trim the CRDs" edit fails at compile time
# instead of at operator startup; the watch invariant has no
# compile-time oracle beyond keeping this table == the chart bundle.
{
  # kind → { plural, version } for every CRD we ship in the VM group.
  # `consumer = true` marks kinds with a kix-side consumer surface
  # (out.mk* builder / sibling package); the rest exist only to satisfy
  # the operator's startup indexers.
  vmCrdDefs = {
    vmClusters = {
      kind = "VMCluster";
      plural = "vmclusters";
      version = "v1beta1";
      consumer = true;
    };
    vmAgents = {
      kind = "VMAgent";
      plural = "vmagents";
      version = "v1beta1";
      consumer = true;
    };
    vmAlerts = {
      kind = "VMAlert";
      plural = "vmalerts";
      version = "v1beta1";
      consumer = true;
    };
    vmAlertmanagers = {
      kind = "VMAlertmanager";
      plural = "vmalertmanagers";
      version = "v1beta1";
      consumer = true;
    };
    vmServiceScrapes = {
      kind = "VMServiceScrape";
      plural = "vmservicescrapes";
      version = "v1beta1";
      consumer = true;
    };
    vmPodScrapes = {
      kind = "VMPodScrape";
      plural = "vmpodscrapes";
      version = "v1beta1";
      consumer = true;
    };
    vmRules = {
      kind = "VMRule";
      plural = "vmrules";
      version = "v1beta1";
      consumer = true;
    };
    vmProbes = {
      kind = "VMProbe";
      plural = "vmprobes";
      version = "v1beta1";
      consumer = true;
    };
    # ── Indexer floor only — no kix consumer surface yet ──────────────
    vmScrapeConfigs = {
      kind = "VMScrapeConfig";
      plural = "vmscrapeconfigs";
      version = "v1beta1";
    };
    vmStaticScrapes = {
      kind = "VMStaticScrape";
      plural = "vmstaticscrapes";
      version = "v1beta1";
    };
    vmNodeScrapes = {
      kind = "VMNodeScrape";
      plural = "vmnodescrapes";
      version = "v1beta1";
    };
    vmUsers = {
      kind = "VMUser";
      plural = "vmusers";
      version = "v1beta1";
    };
    vmAlertmanagerConfigs = {
      kind = "VMAlertmanagerConfig";
      plural = "vmalertmanagerconfigs";
      version = "v1beta1";
    };
    vmAnomalyConfigs = {
      kind = "VMAnomalyConfig";
      plural = "vmanomalyconfigs";
      version = "v1";
    };
    # ── Watch floor only — remaining chart-bundle kinds ────────────────
    vmSingles = {
      kind = "VMSingle";
      plural = "vmsingles";
      version = "v1beta1";
    };
    vmAuths = {
      kind = "VMAuth";
      plural = "vmauths";
      version = "v1beta1";
    };
    vmAnomalies = {
      kind = "VMAnomaly";
      plural = "vmanomalies";
      version = "v1";
    };
    vmDistributed = {
      kind = "VMDistributed";
      plural = "vmdistributed";
      version = "v1alpha1";
    };
    vlAgents = {
      kind = "VLAgent";
      plural = "vlagents";
      version = "v1";
    };
    vlClusters = {
      kind = "VLCluster";
      plural = "vlclusters";
      version = "v1";
    };
    vlSingles = {
      kind = "VLSingle";
      plural = "vlsingles";
      version = "v1";
    };
    vlDistributed = {
      kind = "VLDistributed";
      plural = "vldistributed";
      version = "v1alpha1";
    };
    vlogs = {
      kind = "VLogs";
      plural = "vlogs";
      version = "v1beta1";
    };
    vtClusters = {
      kind = "VTCluster";
      plural = "vtclusters";
      version = "v1";
    };
    vtSingles = {
      kind = "VTSingle";
      plural = "vtsingles";
      version = "v1";
    };
  };

  # ChildConditionIndexedKinds @ v0.74.1 — the hard floor. Update alongside
  # operator version bumps.
  indexedKinds = [
    "VMRule"
    "VMServiceScrape"
    "VMPodScrape"
    "VMProbe"
    "VMScrapeConfig"
    "VMStaticScrape"
    "VMNodeScrape"
    "VMUser"
    "VMAlertmanagerConfig"
    "VMAnomalyConfig"
  ];
}
