# kube-prometheus-stack — full-cluster Prometheus monitoring stack.
#
# Wraps the upstream kube-prometheus-stack Helm chart via fromHelmChart.
# Includes Prometheus, Grafana, Alertmanager, node-exporter, and
# kube-state-metrics.
#
# Chart:   https://prometheus-community.github.io/helm-charts
# Name:    kube-prometheus-stack
# Version: 71.2.0
#
# Usage in cluster definition:
#
#   kube-prometheus-stack = {
#     package = kix.fromHelmChart {
#       chart = kix.fetchHelmChart {
#         repo = "https://prometheus-community.github.io/helm-charts";
#         name = "kube-prometheus-stack";
#         version = "71.2.0";
#         hash = "sha256-FIXME";
#       };
#       values = (import ./packages/kube-prometheus-stack).defaultValues;
#       releaseName = "kube-prometheus-stack";
#       includeCrds = true;
#     };

#     config.values = { /* cluster-level overrides */ };
#   };

{
  meta = {
    version = "71.2.0";
  };

  chart = {
    repo = "https://prometheus-community.github.io/helm-charts";
    name = "kube-prometheus-stack";
    version = "71.2.0";
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
      ingress = {
        enabled = true;
        ingressClassName = "private-v2";
        annotations = {
          "cert-manager.io/issuer" = "letsencrypt-production";
          "cert-manager.io/issuer-kind" = "ClusterIssuer";
          "ingress.kubernetes.io/ssl-redirect" = "true";
        };
        hosts = [ "prometheus.nw1.example.net" ];
        paths = [ "/" ];
        tls = [
          {
            secretName = "prometheus-tls";
            hosts = [ "prometheus.nw1.example.net" ];
          }
        ];
      };
      prometheusSpec = {
        retention = "90d";
        retentionSize = "320GiB";
        replicas = 1;
        resources = {
          requests = {
            cpu = "2";
            memory = "8Gi";
          };
          limits = {
            cpu = "4";
            memory = "16Gi";
          };
        };
        storageSpec.volumeClaimTemplate = {
          metadata = {
            name = "data";
            labels = {
              "velero.io/exclude-from-backup" = "false";
            };
          };
          spec = {
            resources.requests.storage = "400Gi";
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
        priorityClassName = "monitoring-prometheus";
        scrapeInterval = "30s";
        evaluationInterval = "30s";
        externalUrl = "https://prometheus.nw1.example.net";
        additionalAlertRelabelConfigsSecret = {
          name = "prometheus-alert-relabel-config";
          key = "config.yaml";
        };
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
        storageClassName = "lbs1-pool1-2x";
      };
      ingress = {
        enabled = true;
        ingressClassName = "private-v2";
        hosts = [ "grafana.nw1.example.net" ];
        tls = [
          {
            secretName = "grafana-ingress-tls";
            hosts = [ "grafana.nw1.example.net" ];
          }
        ];
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
      priorityClassName = "monitoring-prometheus";
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
      dashboards = {
        default = {
          cardinality-explorer = {
            gnetId = 11304;
            revision = 1;
            datasource = "Prometheus";
          };
        };
      };
      dashboardsConfigMaps = {
        default = "prometheus-grafana-dashboards-default";
      };
      # Admin credentials use the chart-generated secret (prometheus-grafana).
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
        priorityClassName = "monitoring-prometheus";
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
          receiver = "incidentio";
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
          {
            name = "incidentio";
            webhook_configs = [
              {
                url = "https://app.incident.io/webhooks/alertmanager";
                send_resolved = true;
                http_config = {
                  authorization = {
                    type = "Bearer";
                    credentials_file = "/etc/alertmanager/secrets/incidentio-token/token";
                  };
                };
              }
            ];
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

    # --- CoreDNS ---
    # Match actual selector label used in the cluster (coredns, not kube-dns).
    coreDns = {
      enabled = true;
      service = {
        selector = {
          k8s-app = "coredns";
        };
      };
    };

    # --- Global ---
    kubeEtcd.enabled = true;
    kubeProxy.enabled = true;
  };
}
