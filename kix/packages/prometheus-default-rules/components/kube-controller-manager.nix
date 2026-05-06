# kube-controller-manager monitor + bridge Service.
#
# The ServiceMonitor selects on
#   { app = "kube-prometheus-stack-kube-controller-manager"; release = "prometheus"; }
# in kube-system. The bridge Service emitted here carries those labels and a
# pod selector matching the static control-plane pod (component=kube-controller-manager).
# Without the bridge Service, the SM has no targets in a clean install.
#
# For managed clusters where kube-controller-manager isn't a pod (EKS/GKE/AKS),
# set `endpoints` to the IP list and an Endpoints object is emitted instead.

{ lib }:
let
  serviceName = "kube-prometheus-stack-kube-controller-manager";
in
{
  options.monitors.kubeControllerManager = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        selector = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {
            component = "kube-controller-manager";
          };
        };
        port = lib.mkOption {
          type = lib.types.int;
          default = 10257;
        };
        portName = lib.mkOption {
          type = lib.types.str;
          default = "http-metrics";
        };
        endpoints = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            If non-empty, emit an Endpoints object with these IPs instead of
            relying on the Service's pod selector. Use for managed clusters
            where the controller-manager isn't an in-cluster pod.
          '';
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
      cfg = config.monitors.kubeControllerManager;
      mkSmon = prometheusOperator.out.mkServiceMonitor scope;
      kubeSystem = scope.forNamespace "kube-system";
      svcLabels = {
        app = serviceName;
        release = "prometheus";
        jobLabel = "kube-controller-manager";
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
        monitor-kubeControllerManager = mkSmon {
          name = "${scope.instanceName}-kube-controller-manager";
          spec = smonSpec;
        };
        bridge-kubeControllerManager = kubeSystem.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = serviceName;
          labels = svcLabels;
          spec = svcSpec;
        };
      }
      // lib.optionalAttrs (cfg.endpoints != [ ]) {
        endpoints-kubeControllerManager = kubeSystem.mkResource {
          apiVersion = "v1";
          kind = "Endpoints";
          name = serviceName;
          labels = svcLabels // {
            k8s-app = "kube-controller-manager";
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
