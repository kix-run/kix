# Monitoring module — native Prometheus monitoring stack.
#
# Instantiates prometheus-operator, prometheus, alertmanager, node-exporter,
# kube-state-metrics, and grafana as individual native packages.
# Each component is individually configurable and disableable.
#
# Usage:
#   modules = [
#     kix.modules.monitoring
#     {
#       monitoring.enabled = true;
#       monitoring.prometheus.retention = "30d";
#       monitoring.grafana.enabled = false;
#     }
#   ];
#
# For advanced per-instance overrides, use the instances option directly:
#   instances.monitoring-system.prometheus-server.config.storage = { ... };

{
  config,
  lib,
  kix,
  packages,
  ...
}:

let
  cfg = config.monitoring;
  ns = cfg.namespace;
in
{
  options.monitoring = {
    enabled = lib.mkEnableOption "cluster monitoring stack";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "monitoring-system";
    };

    # ── Prometheus Operator ────────────────────────────────────────────
    operator.enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    # ── Prometheus Server ──────────────────────────────────────────────
    prometheus = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      retention = lib.mkOption {
        type = lib.types.str;
        default = "7d";
      };
      retentionSize = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      scrapeInterval = lib.mkOption {
        type = lib.types.str;
        default = "30s";
      };
      resources = lib.mkOption {
        type = lib.types.anything;
        default = {
          requests = {
            cpu = "500m";
            memory = "2Gi";
          };
          limits = {
            cpu = "2";
            memory = "4Gi";
          };
        };
      };
      storage = lib.mkOption {
        type = lib.types.anything;
        default = null;
      };
      externalUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };

    # ── Alertmanager ───────────────────────────────────────────────────
    alertmanager = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      routing = lib.mkOption {
        type = lib.types.nullOr lib.types.anything;
        default = null;
        description = "Override alertmanager routing config (receivers, routes).";
      };
    };

    # ── Node Exporter ──────────────────────────────────────────────────
    nodeExporter.enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    # ── Kube State Metrics ─────────────────────────────────────────────
    kubeStateMetrics.enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    # ── Grafana ────────────────────────────────────────────────────────
    grafana = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      replicas = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Number of Grafana replicas. Use 1 for most setups; persistence.enabled must be false (or RWX storage) for >1.";
      };
      rootUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Grafana root URL. Derived from cluster.domain if null.";
      };
      persistence = lib.mkOption {
        type = lib.types.anything;
        default = {
          enabled = true;
          size = "10Gi";
        };
      };
      extraDatasources = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [ ];
      };
    };

    # ── Default rules & monitors ─────────────────────────────────────
    defaultRules = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Deploy standard Kubernetes monitoring rules and ServiceMonitors.
          Includes ~150 alert rules, ~90 recording rules, and ServiceMonitors
          for kubelet, apiserver, etcd, scheduler, controller-manager, coredns,
          and kube-proxy. Equivalent to kube-prometheus-stack defaults.
        '';
      };
      # Per-group toggles (forwarded to prometheus-default-rules package)
      rules = lib.mkOption {
        type = lib.types.anything;
        default = { };
        description = "Override per-group rule toggles (etcd, kubeApiserver, etc.)";
      };
      monitors = lib.mkOption {
        type = lib.types.anything;
        default = { };
        description = "Override per-component monitor toggles (kubelet, apiserver, etc.)";
      };
    };

    # ── Loki ───────────────────────────────────────────────────────────
    loki = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      namespace = lib.mkOption {
        type = lib.types.str;
        default = "monitoring-loki";
        description = ''
          Namespace where Loki + its PVC live. Loki gets its own namespace so
          the sibling PVC can be named `storage` (matching the immich-style
          DI convention) without colliding with other monitoring PVCs.
        '';
      };
      storageSize = lib.mkOption {
        type = lib.types.str;
        default = "10Gi";
        description = "Size of the persistent volume claim backing single-binary Loki.";
      };
      extraValues = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Extra Helm values forwarded to the loki package's `extraValues`.";
      };
    };

    # ── Promtail ───────────────────────────────────────────────────────
    promtail.enabled = lib.mkOption {
      type = lib.types.bool;
      default = cfg.loki.enabled;
      defaultText = "monitoring.loki.enabled";
    };
  };

  config = lib.mkIf cfg.enabled {
    instances.${ns} =
      let
        grafanaRootUrl =
          if cfg.grafana.rootUrl != null then
            cfg.grafana.rootUrl
          else if config ? cluster && config.cluster ? domain then
            "http://grafana.${config.cluster.domain}"
          else
            "http://grafana.localhost";
      in
      {
        # ── Prometheus Operator ────────────────────────────────────────
        prometheus-operator = lib.mkIf cfg.operator.enabled {
          package = packages.prometheus-operator;
        };

        # ── Prometheus Server ──────────────────────────────────────────
        prometheus-server = lib.mkIf cfg.prometheus.enabled {
          package = packages.prometheus;
          config = {
            retention = cfg.prometheus.retention;
            scrapeInterval = cfg.prometheus.scrapeInterval;
            resources = cfg.prometheus.resources;
          }
          // lib.optionalAttrs (cfg.prometheus.retentionSize != null) {
            retentionSize = cfg.prometheus.retentionSize;
          }
          // lib.optionalAttrs (cfg.prometheus.storage != null) {
            storage = cfg.prometheus.storage;
          }
          // lib.optionalAttrs (cfg.prometheus.externalUrl != null) {
            externalUrl = cfg.prometheus.externalUrl;
          }
          // lib.optionalAttrs cfg.alertmanager.enabled {
            alerting.alertmanagers = [
              {
                namespace = ns;
                name = "alertmanager";
                port = "http-web";
              }
            ];
          };
        };

        # ── Alertmanager ───────────────────────────────────────────────
        alertmanager = lib.mkIf cfg.alertmanager.enabled {
          package = packages.alertmanager;
          config = lib.optionalAttrs (cfg.alertmanager.routing != null) {
            config = cfg.alertmanager.routing;
          };
        };

        # ── Node Exporter ──────────────────────────────────────────────
        node-exporter = lib.mkIf cfg.nodeExporter.enabled {
          package = packages.node-exporter;
        };

        # ── Kube State Metrics ─────────────────────────────────────────
        kube-state-metrics = lib.mkIf cfg.kubeStateMetrics.enabled {
          package = packages.kube-state-metrics;
        };

        # ── Default rules & monitors ─────────────────────────────────
        default-rules = lib.mkIf cfg.defaultRules.enabled {
          package = packages.prometheus-default-rules;
          config = {
            rules = {
              enabled = true;
            }
            // cfg.defaultRules.rules;
            monitors = {
              enabled = true;
            }
            // cfg.defaultRules.monitors;
          };
        };

        # ── Grafana persistent storage (DI sibling) ─────────────────────
        # Storage lives as its own instance so cluster operators control
        # size / storageClass without reaching into grafana's config. The
        # `storage` alias auto-wires into grafana's `storage` dep arg via
        # `persistent-volume-claim.defaultAliases`.
        storage = lib.mkIf (cfg.grafana.enabled && cfg.grafana.persistence.enabled) {
          package = packages."persistent-volume-claim";
          config = {
            size = cfg.grafana.persistence.size;
          }
          //
            lib.optionalAttrs
              (cfg.grafana.persistence ? storageClass && cfg.grafana.persistence.storageClass != null)
              {
                accessModes = [ "ReadWriteOnce" ];
              };
        };

        # ── Grafana ───────────────────────────────────────────────────────
        grafana = lib.mkIf cfg.grafana.enabled {
          package = packages.grafana;
          config = {
            rootUrl = grafanaRootUrl;
            replicas = cfg.grafana.replicas;
            # Loki is still Helm-wrapped so doesn't expose out.serviceUrl via DI.
            # Pass the datasource URL explicitly until Loki is migrated to native.
            datasources =
              lib.optional cfg.loki.enabled {
                name = "Loki";
                type = "loki";
                # Loki lives in its own namespace so the sibling PVC can be
                # called `storage` (immich pattern).
                url = "http://loki-gateway.${cfg.loki.namespace}.svc.cluster.local";
                access = "proxy";
              }
              ++ cfg.grafana.extraDatasources;
          };
        };

        # ── Promtail priority class ───────────────────────────────────
        # Promtail hardcodes priorityClassName = "monitoring-loki". We must
        # create that PriorityClass before the DaemonSet can schedule pods.
        priority-classes = lib.mkIf cfg.promtail.enabled {
          package = packages.priority-classes;
          config.classes = {
            "monitoring-loki" = {
              value = 1000000;
              description = "Monitoring and log shipping workloads (Loki, Promtail)";
            };
          };
        };

        # ── Promtail (Helm) ────────────────────────────────────────────
        promtail = lib.mkIf cfg.promtail.enabled {
          package = kix.fromHelmChart {
            chart = kix.fetchHelmChart {
              repo = "https://grafana.github.io/helm-charts";
              name = "promtail";
              version = "6.16.6";
              hash = "sha256-HezE6O/HucgBrIy88PEd8llsK35ns72GztBZKSed3+4=";
            };
            values = (import ../../packages/promtail).defaultValues;
            releaseName = "promtail";
            rootSelector = {
              kind = "DaemonSet";
              name = "promtail";
            };
          };
        };
      };

    # ── Loki (own namespace, helm-rendered + DI'd sibling PVC) ──────────
    # Lives in its own namespace so the sibling PVC can be named `storage`
    # (immich pattern). The PVC participates in real DI for its
    # storageClassName via the flavor's storageClasses import. Helm
    # rendering happens here at the module level (rather than inside a
    # native package) because the helm bridge isn't available to package
    # build functions — see kix/packages/loki/default.nix for the rationale.
    instances.${cfg.loki.namespace} = lib.mkIf cfg.loki.enabled (
      let
        lokiPkg = import ../../packages/loki;
        # The PVC instance is named "storage", which matches the
        # extraVolumes claimName baked into the package's default values.
        # Same-namespace PVC + StatefulSet → claim resolves by name.
        pvcName = "storage";
        values = lib.recursiveUpdate lokiPkg.defaultValues cfg.loki.extraValues;
      in
      {
        ${pvcName} = {
          package = packages."persistent-volume-claim";
          config.size = cfg.loki.storageSize;
        };
        loki = {
          package = kix.fromHelmChart {
            chart = kix.fetchHelmChart {
              repo = "https://grafana.github.io/helm-charts";
              name = "loki";
              version = "6.24.0";
              hash = "sha256-oMXOPOZZrT+UC5ve7vSWJPsUpeTuyECBTXby7arjyIY=";
            };
            inherit values;
            releaseName = "loki";
            rootSelector = {
              kind = "Service";
              name = "loki-gateway";
            };
          };
        };
      }
    );

    namespaces.${cfg.loki.namespace} = lib.mkIf cfg.loki.enabled { };
  };
}
