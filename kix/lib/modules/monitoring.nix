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
#
# `monitoring.loki.enabled` adds Loki (the loki package) and its claim
# `loki-storage` to the same namespace, and Grafana gets a Loki datasource
# from it. Tune Loki through its own options:
#   instances.monitoring-system.loki.config.settings.limits_config.retention_period = "720h";
# `monitoring.lokiLogs.enabled` (on with Loki) adds the loki-logs agent,
# which ships every pod's logs to that Loki.
#
# node-exporter and loki-logs mount host paths, so the namespace runs at the
# `privileged` Pod Security level. For a restricted monitoring namespace,
# turn both off and declare those agents in a namespace of their own.

{
  config,
  lib,
  kix,
  packages,
  ref,
  ...
}:

let
  cfg = config.monitoring;
  ns = cfg.namespace;
  # The module's `kix` argument carries only `mkImport`, so the quantity
  # type comes from its file rather than `kix.types.quantity`.
  quantity = import ../vocab/quantity.nix { inherit lib; };
  # Instance name of the log shipper's PriorityClass. The instance below
  # creates the class, and loki-logs reads its name through
  # deps.priorityClass, which also orders the DaemonSet after it.
  logShipperPriorityClass = "monitoring-log-shipper";
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
        description = "Alertmanager configuration, passed to the alertmanager instance's `settings`. Null uses that package's configuration, which routes every alert to the receiver `null`.";
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
      storageSize = lib.mkOption {
        type = quantity.type;
        default = "10Gi";
        description = "Size of the claim behind Loki, which holds every log line for the retention period. For a StorageClass, set `instances.<monitoring.namespace>.loki-storage.config.storageClassName`.";
      };
    };

    lokiLogs.enabled = lib.mkOption {
      type = lib.types.bool;
      default = cfg.loki.enabled;
      defaultText = "monitoring.loki.enabled";
      description = "Ship every pod's logs to this module's Loki with the loki-logs Vector agent.";
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
              # The operator's `alertmanager-operated` Service (port `web`),
              # which the alertmanager package refs. The operator turns this
              # into Alertmanager service discovery, so the name must be a
              # Service that exists in the namespace.
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
              settings = cfg.alertmanager.routing;
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
              inherit (cfg.grafana.persistence) storageClassName;
              # The claim's `size` option is a string; the quantity type also
              # accepts a plain number of bytes.
              size = toString cfg.grafana.persistence.size;
            };
          };

          grafana = lib.mkIf cfg.grafana.enabled {
            package = packages.grafana;
            config = {
              rootUrl = grafanaRootUrl;
              datasources = cfg.grafana.extraDatasources;
            };
          };

          ${logShipperPriorityClass} = lib.mkIf cfg.lokiLogs.enabled {
            package = packages.priority-class;
            config = {
              value = 1000000;
              description = "Log shipper DaemonSet of the monitoring stack, so it can preempt lower-priority pods on a full node";
            };
          };

          # Grafana's optional `storage` dependency would otherwise bind
          # Loki's claim in this namespace. A non-empty `aliases` replaces
          # the package's `storage` alias, and nothing resolves `lokiStorage`
          # (housekeeping/2026-10-01-no-way-to-drop-default-aliases.md).
          # clusters/test-monitoring-loki.nix asserts that Grafana then
          # mounts no claim.
          loki-storage = lib.mkIf cfg.loki.enabled {
            package = packages."persistent-volume-claim";
            aliases = [ "lokiStorage" ];
            config.size = cfg.loki.storageSize;
          };

          loki = lib.mkIf cfg.loki.enabled {
            package = packages.loki;
            deps.storage = ref.${ns}.loki-storage;
          };

          loki-logs = lib.mkIf cfg.lokiLogs.enabled {
            package = packages.loki-logs;
            deps.loki =
              if cfg.loki.enabled then
                ref.${ns}.loki
              else
                throw "monitoring.lokiLogs.enabled is true but monitoring.loki.enabled is false, so there is no Loki to ship to. Enable monitoring.loki, or turn lokiLogs off and declare a loki-logs instance with deps.loki pointing at your Loki.";
            deps.priorityClass = ref.${ns}.${logShipperPriorityClass};
          };
        };
      in
      rawInstances;
  };
}
