# Native Prometheus monitoring stack.
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
  quantity = import ../vocab/quantity.nix { inherit lib; };
  # Created by the `priority-classes` instance below and named by promtail.
  # A module cannot read another instance's `out`, so both sides use this
  # name; eval fails if promtail names a class that no resource creates.
  promtailPriorityClass = "monitoring-loki";
in
{
  options.monitoring = {
    enabled = lib.mkEnableOption "cluster monitoring stack";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "monitoring-system";
    };

    operator.enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

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
      storage = lib.mkOption {
        type = lib.types.anything;
        default = null;
      };
      externalUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };

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

    nodeExporter.enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    kubeStateMetrics.enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

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
      persistence = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Keep Grafana's data on a PersistentVolumeClaim (a persistent-volume-claim instance named `storage` in the monitoring namespace). False keeps it in an emptyDir, which a pod restart empties.";
        };
        size = lib.mkOption {
          type = quantity.type;
          default = "10Gi";
          description = "Size of Grafana's claim.";
        };
        storageClassName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "StorageClass of Grafana's claim. Null leaves the choice to the persistent-volume-claim package.";
        };
      };
      extraDatasources = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [ ];
      };
    };

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
      # Forwarded to the prometheus-default-rules package.
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
          # `cluster.domain` always exists and is null when no public domain
          # has been configured.
          else if (config.cluster.domain or null) != null then
            "http://grafana.${config.cluster.domain}"
          else
            "http://grafana.localhost";

        rawInstances = {
          prometheus-operator = lib.mkIf cfg.operator.enabled {
            package = packages.prometheus-operator;
          };

          prometheus-server = lib.mkIf cfg.prometheus.enabled {
            package = packages.prometheus;
            config = {
              retention = cfg.prometheus.retention;
              scrapeInterval = cfg.prometheus.scrapeInterval;
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
              # The alertmanager package no longer renders its own Service; it
              # refs the operator's `alertmanager-operated` (port `web`). The
              # operator turns this into Alertmanager service discovery, so
              # the name must be a Service that exists in the namespace.
              alerting.alertmanagers = [
                {
                  namespace = ns;
                  name = "alertmanager-operated";
                  port = "web";
                }
              ];
            };
          };

          alertmanager = lib.mkIf cfg.alertmanager.enabled {
            package = packages.alertmanager;
            config = lib.optionalAttrs (cfg.alertmanager.routing != null) {
              config = cfg.alertmanager.routing;
            };
          };

          node-exporter = lib.mkIf cfg.nodeExporter.enabled {
            package = packages.node-exporter;
          };

          kube-state-metrics = lib.mkIf cfg.kubeStateMetrics.enabled {
            package = packages.kube-state-metrics;
          };

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

          # Storage lives as its own instance so cluster operators control
          # size / storageClass without reaching into grafana's config. The
          # `storage` alias auto-wires into grafana's `storage` dep arg via
          # `persistent-volume-claim.defaultAliases`.
          storage = lib.mkIf (cfg.grafana.enabled && cfg.grafana.persistence.enabled) {
            package = packages."persistent-volume-claim";
            config = {
              inherit (cfg.grafana.persistence) size storageClassName;
            };
          };

          grafana = lib.mkIf cfg.grafana.enabled {
            package = packages.grafana;
            config = {
              rootUrl = grafanaRootUrl;
              replicas = cfg.grafana.replicas;
              # The Helm-wrapped Loki package does not expose out.serviceUrl.
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

          priority-classes = lib.mkIf cfg.promtail.enabled {
            package = packages.priority-classes;
            config.classes = {
              ${promtailPriorityClass} = {
                value = 1000000;
                description = "Monitoring and log shipping workloads (Loki, Promtail)";
              };
            };
          };

          promtail = lib.mkIf cfg.promtail.enabled {
            package = packages.promtail;
            config.priorityClassName = promtailPriorityClass;
          };
        };
      in
      rawInstances;

    # Loki uses its own namespace so its sibling PVC can be named `storage`.
    # The flavor's storageClasses import supplies the PVC storageClassName.
    # Helm rendering runs at module level because package build functions do
    # not receive the Helm bridge.
    instances.${cfg.loki.namespace} = lib.mkIf cfg.loki.enabled {
      # The PVC instance is named "storage", which matches the
      # extraVolumes claimName baked into the package's default values.
      # The same-namespace StatefulSet resolves the PVC by name.
      storage = {
        package = packages."persistent-volume-claim";
        config.size = cfg.loki.storageSize;
      };
      loki = {
        package = packages.loki;
        config.values = cfg.loki.extraValues;
      };
    };

    namespaces.${cfg.loki.namespace} = lib.mkIf cfg.loki.enabled { };
  };
}
