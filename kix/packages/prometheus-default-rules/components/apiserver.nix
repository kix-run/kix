# kube-apiserver monitor: targets the built-in `kubernetes` Service in
# the `default` namespace; no bridge Service needed.

{ lib, kix }:
let
  # Default drop list mirrors the kube-prometheus-stack chart: drops the
  # high-cardinality histogram buckets that aren't useful for SLO alerts.
  defaultMetricRelabelings = [
    {
      action = "drop";
      regex = "(etcd_request|apiserver_request_slo|apiserver_request_sli|apiserver_request)_duration_seconds_bucket;(0\\.15|0\\.2|0\\.3|0\\.35|0\\.4|0\\.45|0\\.6|0\\.7|0\\.8|0\\.9|1\\.25|1\\.5|1\\.75|2|3|3\\.5|4|4\\.5|6|7|8|9|15|20|40|45|50)(\\.0)?";
      sourceLabels = [
        "__name__"
        "le"
      ];
    }
  ];
in
{
  options.monitors.apiserver = lib.mkOption {
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
          default = "kubernetes";
        };
        insecureSkipVerify = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        metricRelabelings = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = defaultMetricRelabelings;
        };
        relabelings = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
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
      cfg = config.monitors.apiserver;
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

      endpoint = {
        port = "https";
      }
      // lib.optionalAttrs (cfg.scheme == "https") { scheme = "https"; }
      // lib.optionalAttrs (cfg.bearerTokenFile != null) {
        inherit (cfg) bearerTokenFile;
      }
      // lib.optionalAttrs (cfg.interval != null) { inherit (cfg) interval; }
      // lib.optionalAttrs (cfg.proxyUrl != null) { inherit (cfg) proxyUrl; }
      // tlsConfig
      // lib.optionalAttrs (cfg.metricRelabelings != [ ]) { inherit (cfg) metricRelabelings; }
      // lib.optionalAttrs (cfg.relabelings != [ ]) { inherit (cfg) relabelings; };

      smonSpec = {
        jobLabel = "component";
        namespaceSelector.matchNames = [ "default" ];
        selector.matchLabels = {
          component = "apiserver";
          provider = "kubernetes";
        };
        endpoints = [ endpoint ];
      };
    in
    if !(config.monitors.enabled && cfg.enabled) then
      { }
    else
      {
        monitor-apiserver = mkSmon {
          name = "${scope.instanceName}-apiserver";
          # The `kubernetes` Service in `default` is created by the
          # apiserver itself at runtime (see header). Kix renders no
          # Service matching this selector, which the
          # monitorSelectorMatchesService rule would flag on any cluster
          # with a kix instance in `default`. Same situation as kubelet.
          annotations.${kix.keys.monitorsExternalService} = "true";
          spec = smonSpec;
        };
      };
}
