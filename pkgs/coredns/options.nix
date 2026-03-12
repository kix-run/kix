# CoreDNS module options — the user-facing API surface.
#
# Returns chart-specific options only. Enable, namespace, and clusterDomain
# are added automatically by mkChartModule.

{
  lib,
  kixlib,
  opts,
}:

let
  types = lib.types;

  # Plugin constructors — same as helpers.nix, redefined here because options.nix
  # doesn't have access to helpers. Trivial enough that duplication is harmless.
  plugin = name: {
    inherit name;
    parameters = null;
    configBlock = null;
  };
  withParams = parameters: p: p // { inherit parameters; };
  withBlock = configBlock: p: p // { inherit configBlock; };
in
{
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
    type = opts.imageSubmodule {
      repository = "coredns/coredns";
      tag = "1.13.1";
    };
    default = { };
    description = "Container image configuration.";
  };

  resources = lib.mkOption {
    type = opts.resourcesSubmodule {
      defaultLimits = {
        cpu = "100m";
        memory = "128Mi";
      };
      defaultRequests = {
        cpu = "100m";
        memory = "128Mi";
      };
    };
    default = { };
    description = "CPU/memory requests and limits.";
  };

  serviceAccount = lib.mkOption {
    type = types.submodule {
      options = {
        create = lib.mkOption {
          type = types.bool;
          default = false;
          description = "Create a ServiceAccount. Helm default is false.";
        };
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
    type = types.listOf (
      types.submodule {
        options = {
          port = lib.mkOption {
            type = types.int;
            default = 53;
          };
          zones = lib.mkOption {
            type = types.listOf (
              types.submodule {
                options = {
                  zone = lib.mkOption {
                    type = types.str;
                    default = ".";
                  };
                  scheme = lib.mkOption {
                    type = types.nullOr types.str;
                    default = null;
                  };
                  use_tcp = lib.mkOption {
                    type = types.bool;
                    default = false;
                  };
                };
              }
            );
            default = [ { zone = "."; } ];
          };
          plugins = lib.mkOption {
            type = types.listOf (
              types.submodule {
                options = {
                  name = lib.mkOption { type = types.str; };
                  parameters = lib.mkOption {
                    type = types.nullOr types.str;
                    default = null;
                  };
                  configBlock = lib.mkOption {
                    type = types.nullOr types.str;
                    default = null;
                  };
                };
              }
            );
            default = [ ];
          };
        };
      }
    );
    # Default matches Helm chart's values.yaml.
    # Uses the plugin/withParams/withBlock pipe DSL defined above.
    default = [
      {
        zones = [
          {
            zone = ".";
            use_tcp = true;
          }
        ];
        port = 53;
        plugins = [
          (plugin "errors")
          (plugin "health" |> withBlock "lameduck 10s")
          (plugin "ready")
          (
            plugin "kubernetes"
            |> withParams "cluster.local in-addr.arpa ip6.arpa"
            |> withBlock "pods insecure\nfallthrough in-addr.arpa ip6.arpa\nttl 30"
          )
          (plugin "prometheus" |> withParams "0.0.0.0:9153")
          (plugin "forward" |> withParams ". /etc/resolv.conf")
          (plugin "cache" |> withParams "30")
          (plugin "loop")
          (plugin "reload")
          (plugin "loadbalance")
        ];
      }
    ];
  };

  # Prometheus monitoring options — mirrors Helm's prometheus.service and
  # prometheus.monitor values. Both disabled by default (matching Helm).
  prometheus = lib.mkOption {
    type = types.submodule {
      options = {
        service = lib.mkOption {
          type = types.submodule {
            options = {
              enabled = lib.mkOption {
                type = types.bool;
                default = false;
                description = "Create a dedicated metrics Service exposing port 9153.";
              };
              annotations = lib.mkOption {
                type = types.attrsOf types.str;
                default = {
                  "prometheus.io/scrape" = "true";
                  "prometheus.io/port" = "9153";
                };
                description = "Annotations on the metrics Service.";
              };
            };
          };
          default = { };
        };
        monitor = lib.mkOption {
          type = types.submodule {
            options = {
              enabled = lib.mkOption {
                type = types.bool;
                default = false;
                description = "Create a ServiceMonitor targeting the metrics Service.";
              };
              interval = lib.mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Scrape interval. Null uses Prometheus default.";
              };
            };
          };
          default = { };
        };
      };
    };
    default = { };
    description = ''
      Prometheus monitoring configuration. Requires the prometheus plugin
      to be configured in servers[].plugins for metrics to be available.
      prometheus.service creates a dedicated Service for port 9153.
      prometheus.monitor creates a ServiceMonitor (requires Prometheus Operator).
    '';
  };

  zoneFiles = lib.mkOption {
    type = types.listOf (
      types.submodule {
        options = {
          filename = lib.mkOption { type = types.str; };
          domain = lib.mkOption { type = types.str; };
          contents = lib.mkOption { type = types.str; };
        };
      }
    );
    default = [ ];
    description = "Custom zone files to include in the ConfigMap.";
  };

  securityContext = lib.mkOption {
    type = types.attrsOf types.anything;
    default = {
      allowPrivilegeEscalation = false;
      capabilities = {
        add = [ "NET_BIND_SERVICE" ];
        drop = [ "ALL" ];
      };
      readOnlyRootFilesystem = true;
    };
    description = "Container security context. Matches Helm defaults.";
  };

  livenessProbe = lib.mkOption {
    type = opts.probeSubmodule {
      defaults = {
        enabled = true;
        initialDelaySeconds = 60;
        periodSeconds = 10;
        timeoutSeconds = 5;
        failureThreshold = 5;
        successThreshold = 1;
      };
    };
    default = { };
  };

  # PodDisruptionBudget — mirrors Helm's podDisruptionBudget value.
  # Helm creates a PodDisruptionBudget when this is non-empty (truthy in Go templates).
  podDisruptionBudget = lib.mkOption {
    type = types.submodule {
      options = {
        minAvailable = lib.mkOption {
          type = types.nullOr (types.either types.int types.str);
          default = null;
          description = "Minimum available pods. Can be int or percentage string.";
        };
        maxUnavailable = lib.mkOption {
          type = types.nullOr (types.either types.int types.str);
          default = null;
          description = "Maximum unavailable pods. Can be int or percentage string.";
        };
      };
    };
    default = { };
    description = "PodDisruptionBudget config. Created when minAvailable or maxUnavailable is set.";
  };

  # HorizontalPodAutoscaler — mirrors Helm's hpa values.
  # Mutually exclusive with autoscaler (cluster-proportional-autoscaler).
  # When enabled, the Deployment omits replicas (letting HPA control it).
  hpa = lib.mkOption {
    type = types.submodule {
      options = {
        enabled = lib.mkOption {
          type = types.bool;
          default = false;
        };
        minReplicas = lib.mkOption {
          type = types.int;
          default = 1;
        };
        maxReplicas = lib.mkOption {
          type = types.int;
          default = 5;
        };
        metrics = lib.mkOption {
          type = types.listOf types.anything;
          default = [ ];
          description = "HPA metrics spec — passed through directly to spec.metrics.";
        };
      };
    };
    default = { };
  };

  # Cluster-proportional autoscaler — mirrors Helm's autoscaler values.
  # Deploys a sidecar that scales CoreDNS proportionally to cluster size.
  # Mutually exclusive with hpa.
  autoscaler = lib.mkOption {
    type = types.submodule {
      options = {
        enabled = lib.mkOption {
          type = types.bool;
          default = false;
        };
        image = lib.mkOption {
          type = opts.imageSubmodule {
            repository = "registry.k8s.io/cpa/cluster-proportional-autoscaler";
            tag = "v1.9.0";
          };
          default = { };
        };
        resources = lib.mkOption {
          type = opts.resourcesSubmodule {
            defaultLimits = {
              cpu = "20m";
              memory = "10Mi";
            };
            defaultRequests = {
              cpu = "20m";
              memory = "10Mi";
            };
          };
          default = { };
        };
        # Scaling config — passed as JSON to the autoscaler ConfigMap.
        coresPerReplica = lib.mkOption {
          type = types.int;
          default = 256;
        };
        nodesPerReplica = lib.mkOption {
          type = types.int;
          default = 16;
        };
        preventSinglePointFailure = lib.mkOption {
          type = types.bool;
          default = true;
        };
        min = lib.mkOption {
          type = types.int;
          default = 0;
        };
        max = lib.mkOption {
          type = types.int;
          default = 0;
        };
        includeUnschedulableNodes = lib.mkOption {
          type = types.bool;
          default = false;
        };
      };
    };
    default = { };
  };

  readinessProbe = lib.mkOption {
    type = opts.probeSubmodule {
      defaults = {
        enabled = true;
        initialDelaySeconds = 30;
        periodSeconds = 5;
        timeoutSeconds = 5;
        failureThreshold = 1;
        successThreshold = 1;
      };
    };
    default = { };
  };
}
