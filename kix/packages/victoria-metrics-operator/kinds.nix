# Single source of truth for the operator.victoriametrics.com CRD set.
# Consumed by crds.nix (CRD resources) and operator.nix (RBAC plurals),
# so the shipped CRDs and the operator's permissions cannot drift apart.
#
# Runtime invariant: the operator requires its complete CRD bundle, for
# two reasons:
#   1. At startup it unconditionally registers status-condition field
#      indexers for every kind in ChildConditionIndexedKinds
#      (k8stools/child_condition_index.go @ v0.74.1) and the manager
#      crashes immediately ("cannot register status condition indexers")
#      if any of those CRDs is absent.
#   2. It then starts informer watches for every controller; a watch on a
#      missing kind dies ~3 minutes in with "failed to wait for ... caches
#      to sync" (for example *v1.VLAgent) and takes the manager down: a
#      slow crashloop.
# So this table mirrors the chart's crd.yaml bundle for the pinned
# operator version (25 kinds @ 0.67.3 / v0.74.1), plurals verbatim;
# note the irregulars (vmanomalies, vmdistributed, vldistributed).
# crds.nix throws at eval time if the table stops covering
# `indexedKinds`, so a "trim the CRDs" edit fails at compile time
# instead of at operator startup; the watch invariant has no
# compile-time oracle beyond keeping this table == the chart bundle.
{
  # ── monitoring.coreos.com, the converter's input ─────────────────────
  # The prometheus-operator kinds the operator's built-in converter can
  # turn into VM equivalents. One entry per converter the operator has.
  #
  # `version` is the API version upstream prometheus-operator serves for
  # the kind, so a declared CRD and a reference to the real one agree.
  # `env` is the suffix of its VM_ENABLEDPROMETHEUSCONVERTER_* variable,
  # and `builder` says whether the package exposes an out.mk* for the
  # kind. That distinction decides when the CRD is needed:
  #
  #   builder = true   the CRD is part of this package's API surface, so
  #                    it is always present. A cluster can still turn the
  #                    converter off (VM beside Prometheus, where kix
  #                    writes the objects but VM should ignore them).
  #   builder = false  the CRD exists only to feed the converter, so it
  #                    is present exactly when that converter is on.
  #
  # Deriving the CRDs from this table is what makes it impossible to
  # enable a converter for a kind whose CRD is absent. That combination
  # is not a config error, it is a slow crashloop: the controller's watch
  # fails to sync and takes the manager down with it (same failure the VM
  # table below guards against).
  #
  # `convertByDefault` is false for the two without builders. Turning one
  # on adds a CRD, and a cluster that has no ScrapeConfigs should not be
  # handed the machinery for them.
  promCompatDefs = {
    serviceMonitors = {
      kind = "ServiceMonitor";
      plural = "servicemonitors";
      version = "v1";
      shortNames = [ "smon" ];
      env = "SERVICESCRAPE";
      builder = true;
      convertByDefault = true;
    };
    podMonitors = {
      kind = "PodMonitor";
      plural = "podmonitors";
      version = "v1";
      shortNames = [ "pmon" ];
      env = "PODMONITOR";
      builder = true;
      convertByDefault = true;
    };
    prometheusRules = {
      kind = "PrometheusRule";
      plural = "prometheusrules";
      version = "v1";
      shortNames = [ "promrule" ];
      env = "PROMETHEUSRULE";
      builder = true;
      convertByDefault = true;
    };
    probes = {
      kind = "Probe";
      plural = "probes";
      version = "v1";
      shortNames = [ "prb" ];
      env = "PROBE";
      builder = true;
      convertByDefault = true;
    };
    scrapeConfigs = {
      kind = "ScrapeConfig";
      plural = "scrapeconfigs";
      version = "v1alpha1";
      shortNames = [ "scfg" ];
      env = "SCRAPECONFIG";
      builder = false;
      convertByDefault = false;
    };
    alertmanagerConfigs = {
      kind = "AlertmanagerConfig";
      plural = "alertmanagerconfigs";
      version = "v1alpha1";
      shortNames = [ "amcfg" ];
      env = "ALERTMANAGERCONFIG";
      builder = false;
      convertByDefault = false;
    };
  };

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
    # ── Indexer floor only: no kix consumer surface yet ──────────────
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
    # ── Watch floor only: remaining chart-bundle kinds ────────────────
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

  # ChildConditionIndexedKinds @ v0.74.1: the hard floor. Update alongside
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
