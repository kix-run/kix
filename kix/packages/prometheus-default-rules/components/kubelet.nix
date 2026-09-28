# kubelet monitor: targets the operator-managed `kubelet` Service in
# kube-system (created by the prometheus-operator's --kubelet-service flag).
# No bridge Service needed.
#
# Three endpoints are emitted by default: the main kubelet endpoint, cAdvisor
# (/metrics/cadvisor) and probes (/metrics/probes). The shared scheme/tls/
# bearerToken settings apply to all three; per-endpoint relabel/interval
# overrides exist on the cAdvisor / probes sub-options.

{ lib, kix }:
let
  # Default cAdvisor metric drops mirror the kube-prometheus-stack chart;
  # cAdvisor produces a *lot* of metrics that aren't useful for alerting/
  # dashboards and blow up TSDB cardinality.
  cAdvisorDefaultMetricRelabelings = [
    {
      action = "drop";
      regex = "container_cpu_(cfs_throttled_seconds_total|load_average_10s|system_seconds_total|user_seconds_total)";
      sourceLabels = [ "__name__" ];
    }
    {
      action = "drop";
      regex = "container_fs_(io_current|io_time_seconds_total|io_time_weighted_seconds_total|reads_merged_total|sector_reads_total|sector_writes_total|writes_merged_total)";
      sourceLabels = [ "__name__" ];
    }
    {
      action = "drop";
      regex = "container_memory_(mapped_file|swap)";
      sourceLabels = [ "__name__" ];
    }
    {
      action = "drop";
      regex = "container_(file_descriptors|tasks_state|threads_max)";
      sourceLabels = [ "__name__" ];
    }
    {
      action = "drop";
      regex = "container_memory_failures_total;hierarchy";
      sourceLabels = [
        "__name__"
        "scope"
      ];
    }
    {
      action = "drop";
      regex = "container_network_.*;(cali|cilium|cni|lxc|nodelocaldns|tunl).*";
      sourceLabels = [
        "__name__"
        "interface"
      ];
    }
    {
      action = "drop";
      regex = "container_spec.*";
      sourceLabels = [ "__name__" ];
    }
    {
      action = "drop";
      regex = ".+;";
      sourceLabels = [
        "id"
        "pod"
      ];
    }
  ];

  # Default kubelet endpoint metric drops (storage histogram buckets).
  kubeletDefaultMetricRelabelings = [
    {
      action = "drop";
      regex = "(csi_operations|storage_operation_duration)_seconds_bucket;(0.25|2.5|15|25|120|600)(\\.0)?";
      sourceLabels = [
        "__name__"
        "le"
      ];
    }
  ];

  # Shared: replace __metrics_path__ -> metrics_path label on each endpoint.
  defaultRelabelings = [
    {
      action = "replace";
      sourceLabels = [ "__metrics_path__" ];
      targetLabel = "metrics_path";
    }
  ];

  endpointSubmodule = {
    options = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      interval = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      metricRelabelings = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [ ];
      };
    };
  };
in
{
  options.monitors.kubelet = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        scheme = lib.mkOption {
          type = lib.types.enum [
            "http"
            "https"
          ];
          default = "https";
        };
        bearerTokenFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "/var/run/secrets/kubernetes.io/serviceaccount/token";
        };
        interval = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        proxyUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        caFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt";
        };
        certFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        keyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        serverName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        insecureSkipVerify = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        metricRelabelings = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = kubeletDefaultMetricRelabelings;
        };
        relabelings = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = defaultRelabelings;
        };
        cAdvisor = lib.mkOption {
          type = lib.types.submodule {
            options = endpointSubmodule.options // {
              interval = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = "10s";
              };
              metricRelabelings = lib.mkOption {
                type = lib.types.listOf lib.types.anything;
                default = cAdvisorDefaultMetricRelabelings;
              };
            };
          };
          default = { };
        };
        probes = lib.mkOption {
          type = lib.types.submodule {
            options = endpointSubmodule.options;
          };
          default = { };
        };
      };
    };
    default = { };
  };

  build =
    {
      self,
      config,
      scope,
      lib,
      prometheusOperator,
      ...
    }:
    let
      cfg = config.monitors.kubelet;
      mkSmon = prometheusOperator.out.mkServiceMonitor scope;

      tlsConfig = lib.optionalAttrs (cfg.scheme == "https") {
        tlsConfig = {
          inherit (cfg) insecureSkipVerify;
        }
        // lib.optionalAttrs (cfg.serverName != null) { inherit (cfg) serverName; }
        // lib.optionalAttrs (cfg.caFile != null) { inherit (cfg) caFile; }
        // lib.optionalAttrs (cfg.certFile != null) { inherit (cfg) certFile; }
        // lib.optionalAttrs (cfg.keyFile != null) { inherit (cfg) keyFile; };
      };

      # Shared base: scheme/tls/bearerToken/honorLabels/honorTimestamps apply to
      # all three endpoints.
      baseEndpoint = {
        port = "https-metrics";
        honorLabels = true;
        honorTimestamps = true;
      }
      // lib.optionalAttrs (cfg.scheme == "https") { scheme = "https"; }
      // lib.optionalAttrs (cfg.bearerTokenFile != null) {
        inherit (cfg) bearerTokenFile;
      }
      // lib.optionalAttrs (cfg.proxyUrl != null) { inherit (cfg) proxyUrl; }
      // tlsConfig;

      mainEndpoint =
        baseEndpoint
        // lib.optionalAttrs (cfg.interval != null) { inherit (cfg) interval; }
        // lib.optionalAttrs (cfg.metricRelabelings != [ ]) { inherit (cfg) metricRelabelings; }
        // lib.optionalAttrs (cfg.relabelings != [ ]) { inherit (cfg) relabelings; };

      cAdvisorEndpoint =
        baseEndpoint
        // {
          path = "/metrics/cadvisor";
          trackTimestampsStaleness = true;
        }
        // lib.optionalAttrs (cfg.cAdvisor.interval != null) { interval = cfg.cAdvisor.interval; }
        // lib.optionalAttrs (cfg.cAdvisor.metricRelabelings != [ ]) {
          metricRelabelings = cfg.cAdvisor.metricRelabelings;
        }
        // lib.optionalAttrs (defaultRelabelings != [ ]) { relabelings = defaultRelabelings; };

      probesEndpoint =
        baseEndpoint
        // {
          path = "/metrics/probes";
        }
        // lib.optionalAttrs (cfg.probes.interval != null) { interval = cfg.probes.interval; }
        // lib.optionalAttrs (cfg.probes.metricRelabelings != [ ]) {
          metricRelabelings = cfg.probes.metricRelabelings;
        }
        // lib.optionalAttrs (defaultRelabelings != [ ]) { relabelings = defaultRelabelings; };

      endpoints = [
        mainEndpoint
      ]
      ++ lib.optional cfg.cAdvisor.enabled cAdvisorEndpoint
      ++ lib.optional cfg.probes.enabled probesEndpoint;

      smonSpec = {
        attachMetadata.node = false;
        jobLabel = "k8s-app";
        namespaceSelector.matchNames = [ "kube-system" ];
        selector.matchLabels = {
          "app.kubernetes.io/name" = "kubelet";
          k8s-app = "kubelet";
        };
        inherit endpoints;
      };
    in
    if !(config.monitors.enabled && cfg.enabled) then
      { }
    else
      {
        monitor-kubelet = mkSmon {
          name = "${scope.instanceName}-kubelet";
          # The `kubelet` Service is operator-created at runtime (see header)
          # and kix renders no Service matching this selector, which the
          # monitorSelectorMatchesService rule would otherwise flag.
          annotations.${kix.keys.monitorsExternalService} = "true";
          spec = smonSpec;
        };
      };
}
