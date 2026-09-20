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
in
{
  options.monitoring = {
    enabled = lib.mkEnableOption "cluster monitoring stack";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "monitoring-system";
    };

    releaseName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        If set, prefix monitoring instance names so resource names match
        kube-prometheus-stack's helm-release naming. e.g. `releaseName =
        "prometheus"` yields `prometheus-kube-prometheus-operator`,
        `prometheus-grafana`, `prometheus-kube-state-metrics`, etc.
        Use when migrating an existing helm-managed cluster and you need
        byte-level parity with the rendered manifests.
      '';
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

        # Map internal keys to chart template suffixes when releaseName is set.
        # The prefixed instance key becomes "${releaseName}-${chartSuffix.<key>}"
        # which mirrors kube-prometheus-stack's rendered resource names.
        chartSuffix = {
          prometheus-operator = "kube-prometheus-operator";
          prometheus-server = "kube-prometheus-prometheus";
          alertmanager = "kube-prometheus-alertmanager";
          node-exporter = "prometheus-node-exporter";
          kube-state-metrics = "kube-state-metrics";
          grafana = "grafana";
          default-rules = "kube-prometheus";
          # Keep `storage`, the Grafana PVC, unrenamed.
          # Renaming it to `prometheus-grafana` would shadow the package's
          # `storage` alias for grafana's DI (the alias resolver matches the
          # named "storage" instance in the loki namespace before falling
          # back to alias-keyed candidates). PVC name parity is a small,
          # separate concern to fix in the package layer.
        };
        rename =
          k:
          if cfg.releaseName == null || !(chartSuffix ? ${k}) then
            k
          else
            "${cfg.releaseName}-${chartSuffix.${k}}";
        rawInstances = {
          prometheus-operator = lib.mkIf cfg.operator.enabled {
            package = packages.prometheus-operator;
          };

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
              size = cfg.grafana.persistence.size;
            }
            //
              lib.optionalAttrs
                (cfg.grafana.persistence ? storageClass && cfg.grafana.persistence.storageClass != null)
                {
                  accessModes = [ "ReadWriteOnce" ];
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

          # Promtail hardcodes priorityClassName = "monitoring-loki", so the
          # PriorityClass must exist before the DaemonSet can schedule pods.
          priority-classes = lib.mkIf cfg.promtail.enabled {
            package = packages.priority-classes;
            config.classes = {
              "monitoring-loki" = {
                value = 1000000;
                description = "Monitoring and log shipping workloads (Loki, Promtail)";
              };
            };
          };

          promtail = lib.mkIf cfg.promtail.enabled {
            package = packages.promtail;
          };
        };
      in
      lib.mapAttrs' (k: v: lib.nameValuePair (rename k) v) rawInstances;

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
