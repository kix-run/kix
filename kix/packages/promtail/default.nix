# Promtail — log shipping agent for Loki.
#
# Wraps the upstream Grafana Promtail Helm chart.
# Deployed as a DaemonSet that ships container logs to Loki.
#
# Chart:   https://grafana.github.io/helm-charts
# Name:    promtail
# Version: 6.17.1

{ scope, lib }:
let
  chart = scope.helm.fetchHelmChart {
    repo = "https://grafana.github.io/helm-charts";
    name = "promtail";
    version = "6.17.1";
    hash = "sha256-EhFRA6O5STJHP7OHOqZwpo2pUE4vMjwDeQJXCItHnZ8=";
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
      # Loki push endpoint — overridden in build with DI-resolved URL.
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
in
{
  meta.version = "6.17.1";

  options.values = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Helm values to deep-merge with the chart's package-level values.";
  };

  build =
    {
      config,
      scope,
      loki,
      ...
    }:
    let
      lokiValues = {
        config.clients = [
          {
            url = "http://${loki.out.name}/loki/api/v1/push";
            tenant_id = "system";
          }
        ];
      };
      resources = scope.helm.importChart {
        inherit chart scope;
        values = lib.recursiveUpdate (lib.recursiveUpdate defaultValues lokiValues) (config.values or { });
        releaseName = "promtail";
        # Inject loki's store-path context so CNP generation discovers
        # the promtail → loki-gateway egress edge.
        networkDeps = [ loki.out.fqdn ];
      };
    in
    resources.mkParts {
      root = resources.get "DaemonSet" "promtail";
    };
}
