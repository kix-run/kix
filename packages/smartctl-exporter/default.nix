# Smartctl Exporter — SMART disk health metrics for Prometheus.
#
# Wraps the upstream prometheus-smartctl-exporter Helm chart via fromHelmChart.
# Deployed as a DaemonSet with privileged access to host /dev.
#
# Chart:   https://prometheus-community.github.io/helm-charts
# Name:    prometheus-smartctl-exporter
# Version: 0.16.0
#
# Usage in cluster definition:
#
#   smartctl-exporter = {
#     package = kix.fromHelmChart {
#       chart = kix.fetchHelmChart {
#         repo = "https://prometheus-community.github.io/helm-charts";
#         name = "prometheus-smartctl-exporter";
#         version = "0.16.0";
#         hash = "sha256-FIXME";
#       };
#       values = (import ./packages/smartctl-exporter).defaultValues;
#       releaseName = "smartctl-exporter";
#       mainSelector = { kind = "DaemonSet"; };
#     };
#
#     config.values = { /* cluster-level overrides */ };
#   };

{
  chart = {
    repo = "https://prometheus-community.github.io/helm-charts";
    name = "prometheus-smartctl-exporter";
    version = "0.16.0";
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
    };

    prometheusRules = {
      enabled = true;
    };
  };
}
