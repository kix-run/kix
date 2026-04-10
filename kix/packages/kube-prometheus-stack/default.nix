# kube-prometheus-stack — full-cluster Prometheus monitoring stack.
#
# Wraps the upstream kube-prometheus-stack Helm chart via importChart.
# Includes Prometheus, Grafana, Alertmanager, node-exporter, and
# kube-state-metrics.
#
# Chart:   oci://ghcr.io/prometheus-community/charts
# Name:    kube-prometheus-stack
# Version: 71.2.0

{ scope, lib }:
let
  chart = scope.helm.fetchHelmChart {
    repo = "oci://ghcr.io/prometheus-community/charts";
    name = "kube-prometheus-stack";
    version = "71.2.0";
    hash = "sha256-TyftOI7LrTeqbU5IsVjRKb78xC1edDHwegq773QEuUM=";
  };

  defaultValues = {
    # --- Default rule overrides ---
    defaultRules = {
      overrides = {
        KubeDeploymentReplicasMismatch = {
          "for" = "1h";
        };
        KubeHpaMaxedOut = {
          "for" = "6h";
        };
        CPUThrottlingHigh = {
          "for" = "1h";
        };
        NodeDiskIOSaturation = {
          "for" = "6h";
        };
      };
    };

    # --- Prometheus ---
    prometheus = {
      enabled = true;
      prometheusSpec = {
        replicas = 1;
        resources = {
          requests = {
            cpu = "500m";
            memory = "2Gi";
          };
          limits = {
            cpu = "2";
            memory = "4Gi";
          };
        };
        # Scrape all ServiceMonitors across all namespaces.
        serviceMonitorSelectorNilUsesHelmValues = false;
        podMonitorSelectorNilUsesHelmValues = false;
        ruleSelectorNilUsesHelmValues = false;
        probeSelectorNilUsesHelmValues = false;
        scrapeConfigSelectorNilUsesHelmValues = false;
        # Security context.
        securityContext = {
          runAsNonRoot = true;
          runAsUser = 1000;
          runAsGroup = 2000;
          fsGroup = 2000;
        };
        scrapeInterval = "30s";
        evaluationInterval = "30s";
      };
    };

    # --- Grafana ---
    grafana = {
      enabled = true;
      replicas = 1;
      deploymentStrategy = {
        type = "Recreate";
      };
      persistence = {
        enabled = true;
        size = "10Gi";
      };
      resources = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "1";
          memory = "1Gi";
        };
      };
      sidecar = {
        dashboards = {
          enabled = true;
          searchNamespace = "ALL";
        };
        datasources = {
          enabled = true;
        };
      };
      dashboardProviders = {
        "dashboardproviders.yaml" = {
          apiVersion = 1;
          providers = [
            {
              name = "default";
              orgId = 1;
              folder = "default";
              type = "file";
              disableDeletion = false;
              editable = true;
              options = {
                path = "/var/lib/grafana/dashboards/standard";
              };
            }
          ];
        };
      };
    };

    # --- Alertmanager ---
    alertmanager = {
      enabled = true;
      alertmanagerSpec = {
        replicas = 1;
        resources = {
          requests = {
            cpu = "0.01";
            memory = "256Mi";
          };
          limits = {
            cpu = "1";
            memory = "1Gi";
          };
        };
      };
      config = {
        global = {
          resolve_timeout = "5m";
        };
        route = {
          group_by = [
            "namespace"
            "alertname"
          ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "12h";
          receiver = "null";
          routes = [
            {
              receiver = "null";
              matchers = [ "alertname = Watchdog" ];
            }
          ];
        };
        receivers = [
          {
            name = "null";
          }
        ];
      };
    };

    # --- Node Exporter ---
    nodeExporter = {
      enabled = true;
    };
    prometheus-node-exporter = {
      resources = {
        requests = {
          cpu = "10m";
          memory = "32Mi";
        };
        limits = {
          cpu = "1";
          memory = "128Mi";
        };
      };
      extraArgs = [
        "--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$"
        "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/.+)($|/)"
        "--collector.textfile.directory=/var/lib/node_exporter/textfile_collector"
      ];
      extraHostVolumeMounts = [
        {
          name = "textfile-collector";
          hostPath = "/var/lib/node_exporter/textfile_collector";
          mountPath = "/var/lib/node_exporter/textfile_collector";
          readOnly = true;
        }
      ];
    };

    # --- Kube State Metrics ---
    kubeStateMetrics = {
      enabled = true;
    };
    kube-state-metrics = {
      resources = {
        requests = {
          cpu = "10m";
          memory = "64Mi";
        };
        limits = {
          cpu = "1";
          memory = "256Mi";
        };
      };
    };

    # --- Global ---
    kubeEtcd.enabled = true;
    kubeProxy.enabled = true;
  };
in
{
  meta = {
    version = "71.2.0";
    isHelm = true;
  };

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
        releaseName = "prometheus";
        includeCrds = true;
      };
    in
    resources.mkParts {
      root = resources.autoRoot;
    };
}
