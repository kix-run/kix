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
#     packageType = "kube-prometheus-stack";
#     config.values = { /* cluster-level overrides */ };
#   };

{
  chart = {
    repo = "https://prometheus-community.github.io/helm-charts";
    name = "kube-prometheus-stack";
    version = "71.2.0";
  };

  defaultValues = {
    # --- Prometheus ---
    prometheus = {
      enabled = true;
      prometheusSpec = {
        retention = "90d";
        retentionSize = "95GB";
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
        storageSpec.volumeClaimTemplate.spec = {
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = "100Gi";
        };
        # Scrape all ServiceMonitors across all namespaces.
        serviceMonitorSelectorNilUsesHelmValues = false;
        podMonitorSelectorNilUsesHelmValues = false;
        ruleSelectorNilUsesHelmValues = false;
        probeSelectorNilUsesHelmValues = false;
        # Security context.
        securityContext = {
          runAsNonRoot = true;
          runAsUser = 1000;
          runAsGroup = 1000;
          fsGroup = 2000;
        };
      };
    };

    # --- Grafana ---
    grafana = {
      enabled = true;
      replicas = 1;
      persistence = {
        enabled = true;
        size = "10Gi";
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
          memory = "256Mi";
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
          searchNamespace = "ALL";
        };
      };
      # Default admin credentials are managed via external secret.
      admin.existingSecret = "grafana-admin-credentials";
    };

    # --- Alertmanager ---
    alertmanager = {
      enabled = true;
      alertmanagerSpec = {
        replicas = 1;
        resources = {
          requests = {
            cpu = "50m";
            memory = "64Mi";
          };
          limits = {
            cpu = "500m";
            memory = "256Mi";
          };
        };
        storage.volumeClaimTemplate.spec = {
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = "5Gi";
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
          cpu = "50m";
          memory = "32Mi";
        };
        limits = {
          cpu = "250m";
          memory = "128Mi";
        };
      };
    };

    # --- Kube State Metrics ---
    kubeStateMetrics = {
      enabled = true;
    };
    kube-state-metrics = {
      resources = {
        requests = {
          cpu = "50m";
          memory = "64Mi";
        };
        limits = {
          cpu = "500m";
          memory = "256Mi";
        };
      };
    };

    # --- Global ---
    # Disable components we handle separately or don't need.
    kubeProxy.enabled = false;
    kubeEtcd.enabled = false;
  };
}
