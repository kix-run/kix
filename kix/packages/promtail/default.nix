# Promtail: log shipping agent for Loki.
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
    # Chart 6.17.1 is the final promtail chart (deprecated upstream in
    # favor of Alloy); it bundles promtail 3.5.1. Pin the newer image
    # explicitly since the chart will not be updated again.
    image.tag = "3.6.11";

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
      # Loki push endpoint, overridden in build with DI-resolved URL.
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
  meta.description = "Promtail from the upstream Helm chart, a DaemonSet that ships container logs to Loki";
  # A log-shipping agent: it reads /var/log and the container runtime's log
  # directory from the host, which the chart does as root. Audited by
  # unsafeGrants.
  meta.unsafe = [ "run-as-root" ];
  meta.owner = "platform";

  options = {
    values = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Helm values to deep-merge with the chart's package-level values.";
    };
    priorityClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "PriorityClass for the DaemonSet pods. Null leaves it unset, as the upstream chart does, so the pods get the cluster's default priority.";
    };
  };

  build =
    {
      config,
      scope,
      loki,
      ...
    }:
    let
      priorityValues = lib.optionalAttrs (config.priorityClassName != null) {
        inherit (config) priorityClassName;
      };
      lokiValues = {
        config.clients = [
          {
            url = "http://${loki.out.fqdn}/loki/api/v1/push";
            tenant_id = "system";
          }
        ];
      };
      resources = scope.helm.importChart {
        inherit chart scope;
        values = lib.foldl' lib.recursiveUpdate defaultValues [
          lokiValues
          priorityValues
          (config.values or { })
        ];
        releaseName = "promtail";
        # Auto-collect loki.out.* context so CNP generation discovers
        # the promtail → loki-gateway egress edge. This replaces the
        # explicit `networkDeps = [ loki.out.fqdn ]` from before.
        deps = [ loki ];
      };
    in
    resources.mkParts {
      root = resources.get "DaemonSet" "promtail";
    };
}
