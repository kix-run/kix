# CoreDNS module options — the user-facing API surface.
#
# This file declares all configurable options for services.coredns.
# Resource construction and config wiring live in resources.nix.

{
  lib,
  ...
}:

let
  types = lib.types;
in
{
  options.services.coredns = {
    enable = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Enable CoreDNS service.";
    };

    namespace = lib.mkOption {
      type = types.str;
      default = "default";
      description = "Kubernetes namespace for all CoreDNS resources.";
    };

    clusterDomain = lib.mkOption {
      type = types.str;
      default = "cluster.local";
      description = "Kubernetes cluster domain for DNS resolution.";
    };

    isClusterService = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Whether to label this as a cluster service (adds k8s-app, kubernetes.io/cluster-service labels).";
    };

    replicaCount = lib.mkOption {
      type = types.int;
      default = 1;
      description = "Number of CoreDNS replicas.";
    };

    image = lib.mkOption {
      type = types.submodule {
        options = {
          repository = lib.mkOption { type = types.str; default = "coredns/coredns"; };
          tag = lib.mkOption { type = types.str; default = "1.13.1"; };
          pullPolicy = lib.mkOption { type = types.str; default = "IfNotPresent"; };
        };
      };
      default = { };
      description = "Container image configuration.";
    };

    resources = lib.mkOption {
      type = types.submodule {
        options = {
          limits = lib.mkOption { type = types.attrsOf types.str; default = { cpu = "100m"; memory = "128Mi"; }; };
          requests = lib.mkOption { type = types.attrsOf types.str; default = { cpu = "100m"; memory = "128Mi"; }; };
        };
      };
      default = { };
      description = "CPU/memory requests and limits.";
    };

    serviceAccount = lib.mkOption {
      type = types.submodule {
        options = {
          create = lib.mkOption { type = types.bool; default = false; description = "Create a ServiceAccount. Helm default is false."; };
        };
      };
      default = { };
    };

    serviceType = lib.mkOption {
      type = types.str;
      default = "ClusterIP";
      description = "Service type (ClusterIP, NodePort, LoadBalancer).";
    };

    # Server blocks — the core of CoreDNS config. Matches Helm values.servers structure.
    servers = lib.mkOption {
      type = types.listOf (types.submodule {
        options = {
          port = lib.mkOption { type = types.int; default = 53; };
          zones = lib.mkOption {
            type = types.listOf (types.submodule {
              options = {
                zone = lib.mkOption { type = types.str; default = "."; };
                scheme = lib.mkOption { type = types.nullOr types.str; default = null; };
                use_tcp = lib.mkOption { type = types.bool; default = false; };
              };
            });
            default = [{ zone = "."; }];
          };
          plugins = lib.mkOption {
            type = types.listOf (types.submodule {
              options = {
                name = lib.mkOption { type = types.str; };
                parameters = lib.mkOption { type = types.nullOr types.str; default = null; };
                configBlock = lib.mkOption { type = types.nullOr types.str; default = null; };
              };
            });
            default = [];
          };
        };
      });
      # Default matches Helm chart's values.yaml
      default = [{
        zones = [{ zone = "."; use_tcp = true; }];
        port = 53;
        plugins = [
          { name = "errors"; }
          { name = "health"; configBlock = "lameduck 10s"; }
          { name = "ready"; }
          { name = "kubernetes"; parameters = "cluster.local in-addr.arpa ip6.arpa"; configBlock = "pods insecure\nfallthrough in-addr.arpa ip6.arpa\nttl 30"; }
          { name = "prometheus"; parameters = "0.0.0.0:9153"; }
          { name = "forward"; parameters = ". /etc/resolv.conf"; }
          { name = "cache"; parameters = "30"; }
          { name = "loop"; }
          { name = "reload"; }
          { name = "loadbalance"; }
        ];
      }];
    };

    zoneFiles = lib.mkOption {
      type = types.listOf (types.submodule {
        options = {
          filename = lib.mkOption { type = types.str; };
          domain = lib.mkOption { type = types.str; };
          contents = lib.mkOption { type = types.str; };
        };
      });
      default = [];
      description = "Custom zone files to include in the ConfigMap.";
    };

    securityContext = lib.mkOption {
      type = types.attrsOf types.anything;
      default = {
        allowPrivilegeEscalation = false;
        capabilities = { add = ["NET_BIND_SERVICE"]; drop = ["ALL"]; };
        readOnlyRootFilesystem = true;
      };
      description = "Container security context. Matches Helm defaults.";
    };

    livenessProbe = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption { type = types.bool; default = true; };
          initialDelaySeconds = lib.mkOption { type = types.int; default = 60; };
          periodSeconds = lib.mkOption { type = types.int; default = 10; };
          timeoutSeconds = lib.mkOption { type = types.int; default = 5; };
          failureThreshold = lib.mkOption { type = types.int; default = 5; };
          successThreshold = lib.mkOption { type = types.int; default = 1; };
        };
      };
      default = { };
    };

    readinessProbe = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption { type = types.bool; default = true; };
          initialDelaySeconds = lib.mkOption { type = types.int; default = 30; };
          periodSeconds = lib.mkOption { type = types.int; default = 5; };
          timeoutSeconds = lib.mkOption { type = types.int; default = 5; };
          failureThreshold = lib.mkOption { type = types.int; default = 1; };
          successThreshold = lib.mkOption { type = types.int; default = 1; };
        };
      };
      default = { };
    };
  };
}
