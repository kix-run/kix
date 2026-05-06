# etcd monitor + bridge Service.
#
# Unlike the other components, the SM spec is constructed in Nix (not loaded
# from frozen JSON) so TLS knobs are pluggable. Real-world etcd scrapes
# usually require client-cert auth — secrets mounted via Prometheus's
# `secrets:` field, then referenced here as caFile/certFile/keyFile.
#
# Example wiring an etcd-client-cert Secret:
#   monitors.etcd = {
#     scheme = "https";
#     caFile = "/etc/prometheus/secrets/etcd-client-cert/ca.crt";
#     certFile = "/etc/prometheus/secrets/etcd-client-cert/tls.crt";
#     keyFile = "/etc/prometheus/secrets/etcd-client-cert/tls.key";
#     insecureSkipVerify = false;
#     serverName = "etcd.local";
#   };

{ lib }:
let
  serviceName = "kube-prometheus-stack-kube-etcd";
in
{
  options.monitors.etcd = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        selector = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {
            component = "etcd";
          };
        };
        port = lib.mkOption {
          type = lib.types.int;
          default = 2381;
        };
        portName = lib.mkOption {
          type = lib.types.str;
          default = "http-metrics";
        };
        endpoints = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        scheme = lib.mkOption {
          type = lib.types.enum [
            "http"
            "https"
          ];
          default = "http";
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
          default = null;
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
          default = false;
        };
        metricRelabelings = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
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
      cfg = config.monitors.etcd;
      mkSmon = prometheusOperator.out.mkServiceMonitor scope;
      kubeSystem = scope.forNamespace "kube-system";
      svcLabels = {
        app = serviceName;
        release = "prometheus";
        jobLabel = "kube-etcd";
      };
      svcSpec = {
        clusterIP = "None";
        type = "ClusterIP";
        ports = [
          {
            name = cfg.portName;
            port = cfg.port;
            targetPort = cfg.port;
            protocol = "TCP";
          }
        ];
      }
      // lib.optionalAttrs (cfg.endpoints == [ ]) { selector = cfg.selector; };

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
        port = cfg.portName;
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
        jobLabel = "jobLabel";
        namespaceSelector.matchNames = [ "kube-system" ];
        selector.matchLabels = {
          app = serviceName;
          release = "prometheus";
        };
        endpoints = [ endpoint ];
      };
    in
    if !(config.monitors.enabled && cfg.enabled) then
      { }
    else
      {
        monitor-etcd = mkSmon {
          name = "${scope.instanceName}-kube-etcd";
          spec = smonSpec;
        };
        bridge-etcd = kubeSystem.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = serviceName;
          labels = svcLabels;
          spec = svcSpec;
        };
      }
      // lib.optionalAttrs (cfg.endpoints != [ ]) {
        endpoints-etcd = kubeSystem.mkResource {
          apiVersion = "v1";
          kind = "Endpoints";
          name = serviceName;
          labels = svcLabels // {
            k8s-app = "etcd-server";
          };
          extra.subsets = [
            {
              addresses = map (ip: { ip = ip; }) cfg.endpoints;
              ports = [
                {
                  name = cfg.portName;
                  port = cfg.port;
                  protocol = "TCP";
                }
              ];
            }
          ];
        };
      };
}
