# Native Prometheus monitoring stack.
#
# Instantiates prometheus-operator, prometheus, alertmanager, node-exporter,
# kube-state-metrics, and grafana as individual native packages in
# `monitoring.namespace`. Each component can be disabled independently.
# Prometheus routes alerts to Alertmanager, Grafana configures Prometheus,
# Alertmanager, and Loki as datasources, and `default-rules` registers scrape
# targets for the other instances.
#
# Usage:
#   modules = [
#     kix.modules.monitoring
#     {
#       monitoring.enabled = true;
#       monitoring.prometheus.retention = "30d";
#       # Provide Grafana's administrator credentials via the `grafanaAdmin`
#       # alias with `admin-user` and `admin-password` keys.
#       instances.monitoring-system.grafana-admin = {
#         package = packages.secret;
#         aliases = [ "grafanaAdmin" ];
#         config.source = ./secrets/grafana-admin.sops.yaml;
#         config.keys = [ "admin-user" "admin-password" ];
#       };
#     }
#   ];
#
# For anything else, set the instance's config directly:
#   instances.monitoring-system.prometheus-server.config.extraSpec.remoteWrite = [ ... ];
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
  # A Prometheus duration: 30s, 7d, 1h30m.
  duration = lib.types.strMatching "([0-9]+(ms|s|m|h|d|w|y))+";
  # Instance name of the log shipper's PriorityClass. The instance below
  # creates the class, and loki-logs reads its name through
  # deps.priorityClass, which also orders the DaemonSet after it.
  logShipperPriorityClass = "monitoring-log-shipper";
  controlPlaneMonitors = [
    "etcd"
    "kubeControllerManager"
    "kubeScheduler"
  ];
  unreachableMonitors =
    if config.cluster.provider == "kind" then
      controlPlaneMonitors ++ [ "kubeProxy" ]
    else if config.cluster.capabilities.managedControlPlane == true then
      controlPlaneMonitors
    else
      [ ];
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
        type = duration;
        default = "7d";
        description = "How long Prometheus keeps samples (the resource's `retention`).";
      };
      retentionSize = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[0-9]+(\\.[0-9]+)?(B|KB|MB|GB|TB|PB|EB)");
        default = null;
        example = "40GB";
        description = "The most data Prometheus keeps, in Prometheus units (`retentionSize`). Null sets no limit.";
      };
      scrapeInterval = lib.mkOption {
        type = duration;
        default = "30s";
        description = "Default scrape interval (`scrapeInterval`).";
      };
      storage = {
        size = lib.mkOption {
          type = lib.types.nullOr quantity.type;
          default = null;
          example = "50Gi";
          description = "Size of each Prometheus server's data volume, in the class of the cluster's `storageClasses` provider. For another class, set `instances.<monitoring.namespace>.prometheus-server.deps.storageClasses`. Null keeps the data in an emptyDir.";
        };
      };
    };

    alertmanager = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      settings = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
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
        description = "Run Grafana. It needs a `grafanaAdmin` secret in the namespace (see the module header).";
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
      datasources = lib.mkOption {
        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
        default = [ ];
        description = "Datasources added after the wired ones, passed to the grafana instance's `datasources`.";
      };
    };

    defaultRules.enabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Deploy the prometheus-default-rules package: the standard Kubernetes
        alerting and recording rules, and ServiceMonitors for the API
        server, the kubelets, CoreDNS, etcd, kube-controller-manager,
        kube-scheduler, and kube-proxy. On kind the etcd,
        kube-controller-manager, kube-scheduler, and kube-proxy monitors
        default to off, and under a managed control plane the first three,
        because their metrics cannot be reached. Turn single rule groups or
        monitors on or off through
        `instances.<namespace>.default-rules.config`.
      '';
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
        rawInstances = {
          prometheus-operator = lib.mkIf cfg.operator.enabled {
            package = packages.prometheus-operator;
          };

          # Each value is a default, so the instance's own extraSpec wins.
          prometheus-server = lib.mkIf cfg.prometheus.enabled {
            package = packages.prometheus;
            config = {
              extraSpec = lib.mapAttrs (_: lib.mkDefault) (
                {
                  inherit (cfg.prometheus) retention scrapeInterval;
                }
                // lib.optionalAttrs (cfg.prometheus.retentionSize != null) {
                  inherit (cfg.prometheus) retentionSize;
                }
              );
              inherit (cfg.prometheus) storage;
            };
          };

          alertmanager = lib.mkIf cfg.alertmanager.enabled {
            package = packages.alertmanager;
            config = lib.optionalAttrs (cfg.alertmanager.settings != null) {
              inherit (cfg.alertmanager) settings;
            };
          };

          # The default rules carry the same disk alerts by name.
          node-exporter = lib.mkIf cfg.nodeExporter.enabled {
            package = packages.node-exporter;
            config.metrics.hostAlerts = !cfg.defaultRules.enabled;
          };

          kube-state-metrics = lib.mkIf cfg.kubeStateMetrics.enabled {
            package = packages.kube-state-metrics;
          };

          # kind's kubeadm binds these components' metrics to 127.0.0.1, and
          # a managed control plane runs the first three outside the
          # cluster, so their targets would always be down.
          default-rules = lib.mkIf cfg.defaultRules.enabled {
            package = packages.prometheus-default-rules;
            config.monitors = lib.genAttrs unreachableMonitors (_: {
              enabled = lib.mkDefault false;
            });
          };

          # Storage lives as its own instance so cluster operators control
          # size / storageClass without reaching into grafana's config. The
          # `storage` alias auto-wires into grafana's `storage` dep arg via
          # `persistent-volume-claim.defaultAliases`.
          storage = lib.mkIf (cfg.grafana.enabled && cfg.grafana.persistence.enabled) {
            package = packages."persistent-volume-claim";
            config = {
              inherit (cfg.grafana.persistence) storageClassName;
              # Convert `size` to a string because `quantity.type` also accepts
              # integers while `persistent-volume-claim` expects a string.
              size = toString cfg.grafana.persistence.size;
            };
          };

          grafana = lib.mkIf cfg.grafana.enabled {
            package = packages.grafana;
            config.datasources = cfg.grafana.datasources;
          };

          ${logShipperPriorityClass} = lib.mkIf cfg.lokiLogs.enabled {
            package = packages.priority-class;
            config = {
              value = 1000000;
              description = "Log shipper DaemonSet of the monitoring stack, so it can preempt lower-priority pods on a full node";
            };
          };

          # Override the package's default `storage` alias with `lokiStorage` so
          # Grafana's optional `storage` dependency does not bind Loki's PVC
          # when Grafana persistence is disabled.
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
