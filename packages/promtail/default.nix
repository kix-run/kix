# Promtail — log shipping agent for Loki.
#
# Wraps the upstream Grafana Promtail Helm chart via fromHelmChart.
# Deployed as a DaemonSet that ships container logs to Loki.
#
# Chart:   https://grafana.github.io/helm-charts
# Name:    promtail
# Version: 6.16.6
#
# Usage in cluster definition:
#
#   promtail = {
#     package = kix.fromHelmChart {
#       chart = kix.fetchHelmChart {
#         repo = "https://grafana.github.io/helm-charts";
#         name = "promtail";
#         version = "6.16.6";
#         hash = "sha256-FIXME";
#       };
#       values = (import ./packages/promtail).defaultValues;
#       releaseName = "promtail";
#       mainSelector = { kind = "DaemonSet"; name = "promtail"; };
#     };

#     config.values = { /* cluster-level overrides */ };
#   };

{
  chart = {
    repo = "https://grafana.github.io/helm-charts";
    name = "promtail";
    version = "6.16.6";
  };

  defaultValues = {
    # --- DaemonSet configuration ---
    resources = {
      requests = {
        cpu = "250m";
        memory = "256Mi";
      };
      limits = {
        cpu = "1";
        memory = "1Gi";
      };
    };

    priorityClassName = "monitoring-loki";

    tolerations = [
      # Run on all nodes including control plane.
      {
        key = "node-role.kubernetes.io/control-plane";
        operator = "Exists";
        effect = "NoSchedule";
      }
      {
        key = "node-role.kubernetes.io/master";
        operator = "Exists";
        effect = "NoSchedule";
      }
    ];

    # --- Promtail config ---
    config = {
      # Loki push endpoint — points to the loki-gateway Service.
      clients = [
        {
          url = "http://loki-gateway/loki/api/v1/push";
          tenant_id = "system";
        }
      ];

      snippets = {
        # CRI log format parsing (containerd / CRI-O).
        pipelineStages = [
          { cri = { }; }
        ];

        # Extra relabel configs for multi-tenant support.
        extraRelabelConfigs = [
          # Forward namespace as a label for easier filtering.
          {
            source_labels = [ "__meta_kubernetes_namespace" ];
            target_label = "namespace";
          }
          {
            source_labels = [ "__meta_kubernetes_pod_name" ];
            target_label = "pod";
          }
          {
            source_labels = [ "__meta_kubernetes_pod_container_name" ];
            target_label = "container";
          }
          {
            source_labels = [ "__meta_kubernetes_pod_node_name" ];
            target_label = "node";
          }
        ];
      };
    };

    # --- Service account ---
    serviceAccount = {
      create = true;
    };

    # --- Volume mounts for log access ---
    # The chart handles /var/log and /var/lib/docker/containers by default.
    extraVolumes = [ ];
    extraVolumeMounts = [ ];

    # --- Disable components we don't need ---
    serviceMonitor = {
      enabled = true;
      labels = { };
    };
  };
}
