# kube-scheduler monitor + bridge Service. See kube-controller-manager.nix for rationale.

{
  lib,
  kix,
  bridgeName,
}:
let
  defaultSelector = {
    component = "kube-scheduler";
  };
in
{
  options.monitors.kubeScheduler = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        selector = lib.mkOption {
          type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
          default = null;
          defaultText = lib.literalExpression ''{ component = "kube-scheduler"; }'';
          description = "Pod labels the bridge Service selects when `endpoints` is empty. A value replaces the package's selector as a whole. Null uses `{ component = \"kube-scheduler\"; }`, the label kubeadm puts on its static pods.";
        };
        port = lib.mkOption {
          type = lib.types.int;
          default = 10259;
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
      cfg = config.monitors.kubeScheduler;
      serviceName = bridgeName scope "kube-scheduler";
      mkSmon = prometheusOperator.out.mkServiceMonitor scope;
      kubeSystem = scope.forNamespace "kube-system";
      svcLabels = {
        "app.kubernetes.io/name" = serviceName;
        jobLabel = "kube-scheduler";
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
      // lib.optionalAttrs (cfg.endpoints == [ ]) {
        selector = if cfg.selector == null then defaultSelector else cfg.selector;
      };

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
          "app.kubernetes.io/name" = serviceName;
        };
        endpoints = [ endpoint ];
      };
    in
    if !(config.monitors.enabled && cfg.enabled) then
      { }
    else
      {
        monitor-kubeScheduler = mkSmon {
          name = "${scope.instanceName}-kube-scheduler";
          spec = smonSpec;
        };
        bridge-kubeScheduler = kubeSystem.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = serviceName;
          labels = svcLabels;
          spec = svcSpec;
        };
      }
      // lib.optionalAttrs (cfg.endpoints != [ ]) {
        endpoints-kubeScheduler = kubeSystem.mkResource {
          apiVersion = "v1";
          kind = "Endpoints";
          name = serviceName;
          labels = svcLabels // {
            k8s-app = "kube-scheduler";
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
