# Smartctl Exporter: SMART disk health metrics for Prometheus.
#
# Wraps the upstream prometheus-smartctl-exporter Helm chart.
# Deployed as a DaemonSet with privileged access to host /dev.
#
# Chart:   https://prometheus-community.github.io/helm-charts
# Name:    prometheus-smartctl-exporter
# Version: 0.16.0

{ scope, lib }:
let
  chart = scope.helm.fetchHelmChart {
    repo = "https://prometheus-community.github.io/helm-charts";
    name = "prometheus-smartctl-exporter";
    version = "0.16.0";
    hash = "sha256-YVZTmmCuNnRYeDDBLQNWib4+FBo4mjMCqM5EKyd/Gss=";
  };

  defaultValues = {
    image = {
      repository = "quay.io/prometheuscommunity/smartctl-exporter";
      tag = "v0.14.0";
    };

    resources = {
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits = {
        cpu = "2";
        memory = "64Mi";
      };
    };

    tolerations = [
      {
        effect = "NoSchedule";
        operator = "Exists";
      }
    ];

    serviceMonitor = {
      enabled = true;
      relabelings = [
        {
          action = "replace";
          sourceLabels = [ "__meta_kubernetes_pod_node_name" ];
          targetLabel = "node";
        }
      ];
    };

    prometheusRules = {
      enabled = true;
    };
  };
in
{
  meta.version = "0.16.0";
  meta.description = "smartctl_exporter from the upstream Helm chart, a privileged DaemonSet that exports SMART disk health metrics to Prometheus";
  meta.owner = "platform";
  # smartctl reads SMART data from the node's block devices, which needs a
  # privileged container running as root.
  meta.unsafe = [
    "privileged"
    "run-as-root"
  ];

  options.values = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Helm values to deep-merge with the chart's package-level values.";
  };

  build =
    { config, scope, ... }:
    let
      resources = scope.helm.importChart {
        inherit chart scope;
        values = lib.recursiveUpdate defaultValues (config.values or { });
        releaseName = "smartctl-exporter";
      };
    in
    resources.mkParts {
      root = builtins.head (resources.byKind "DaemonSet");
    };
}
