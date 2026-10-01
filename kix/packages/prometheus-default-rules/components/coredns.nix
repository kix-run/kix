# coredns monitor + bridge Service. See kube-controller-manager.nix for rationale.
# CoreDNS runs as pods in kube-system, so the bridge Service always selects
# pods and this component has no `endpoints` option.

{
  lib,
  kix,
  bridgeName,
}:
let
  defaultSelector = {
    k8s-app = "kube-dns";
  };
in
{
  options.monitors.coredns = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        selector = lib.mkOption {
          type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
          default = null;
          defaultText = lib.literalExpression ''{ k8s-app = "kube-dns"; }'';
          description = "Pod labels the bridge Service selects. A value replaces the package's selector as a whole. Null uses `{ k8s-app = \"kube-dns\"; }`, the label CoreDNS carries in kubeadm clusters.";
        };
        port = lib.mkOption {
          type = lib.types.int;
          default = 9153;
        };
        portName = lib.mkOption {
          type = lib.types.str;
          default = "http-metrics";
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
      cfg = config.monitors.coredns;
      serviceName = bridgeName scope "coredns";
      mkSmon = prometheusOperator.out.mkServiceMonitor scope;
      kubeSystem = scope.forNamespace "kube-system";

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
        monitor-coredns = mkSmon {
          name = "${scope.instanceName}-coredns";
          spec = smonSpec;
        };
        bridge-coredns = kubeSystem.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = serviceName;
          labels = {
            "app.kubernetes.io/name" = serviceName;
            jobLabel = "coredns";
          };
          spec = {
            clusterIP = "None";
            type = "ClusterIP";
            selector = if cfg.selector == null then defaultSelector else cfg.selector;
            ports = [
              {
                name = cfg.portName;
                port = cfg.port;
                targetPort = cfg.port;
                protocol = "TCP";
              }
            ];
          };
        };
      };
}
