# CoreDNS package — v2.
#
# Migrated from pkgs-fp/coredns/ (v1 fixpoint pattern).
# Source Helm chart: coredns/coredns (v1.45.0, appVersion 1.13.1)
#
# The `main` resource is the DNS Service — consumers connect to kube-dns:53.
# Deploying the closure includes the Deployment, RBAC, ConfigMap, and
# everything else needed to make that Service work.
#
# Domain-specific helpers (Corefile builder, port derivation) are imported
# from helpers.nix, unchanged from v1.

{ scope, config, lib }:

let
  helpers = import ./helpers.nix { inherit lib; };
  inherit (helpers) plugin withParams withBlock;

  cfg = scope.defaults config {
    image = {
      repository = "coredns/coredns";
      tag = "1.13.1";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 1;
    isClusterService = true;
    serviceType = "ClusterIP";
    serviceAccount = {
      create = false;
    };
    servers = [
      {
        zones = [
          {
            zone = ".";
            scheme = null;
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
    zoneFiles = [ ];
    resources = {
      limits = {
        cpu = "100m";
        memory = "128Mi";
      };
      requests = {
        cpu = "100m";
        memory = "128Mi";
      };
    };
    securityContext = {
      allowPrivilegeEscalation = false;
      capabilities = {
        add = [ "NET_BIND_SERVICE" ];
        drop = [ "ALL" ];
      };
      readOnlyRootFilesystem = true;
    };
    livenessProbe = {
      enabled = true;
      initialDelaySeconds = 60;
      periodSeconds = 10;
      timeoutSeconds = 5;
      failureThreshold = 5;
      successThreshold = 1;
    };
    readinessProbe = {
      enabled = true;
      initialDelaySeconds = 30;
      periodSeconds = 5;
      timeoutSeconds = 5;
      failureThreshold = 1;
      successThreshold = 1;
    };
    hpa = {
      enabled = false;
      minReplicas = 1;
      maxReplicas = 5;
      metrics = [ ];
    };
    podDisruptionBudget = {
      minAvailable = null;
      maxUnavailable = null;
    };
    prometheus = {
      service = {
        enabled = false;
        annotations = {
          "prometheus.io/scrape" = "true";
          "prometheus.io/port" = "9153";
        };
      };
      monitor = {
        enabled = false;
        interval = null;
      };
    };
    autoscaler = {
      enabled = false;
      image = {
        repository = "registry.k8s.io/cpa/cluster-proportional-autoscaler";
        tag = "v1.9.0";
        pullPolicy = "IfNotPresent";
      };
      resources = {
        limits = {
          cpu = "20m";
          memory = "10Mi";
        };
        requests = {
          cpu = "20m";
          memory = "10Mi";
        };
      };
      coresPerReplica = 256;
      nodesPerReplica = 16;
      preventSinglePointFailure = true;
      min = 0;
      max = 0;
      includeUnschedulableNodes = false;
    };
  };

  # --- Derived values ---
  imageRef = "${cfg.image.repository}:${cfg.image.tag}";
  hasPrometheus = builtins.any (s: builtins.any (p: p.name == "prometheus") s.plugins) cfg.servers;
  corefile = helpers.buildCorefile cfg.servers;
  ports = helpers.derivePorts cfg.servers;
  pdbEnabled = cfg.podDisruptionBudget.minAvailable != null || cfg.podDisruptionBudget.maxUnavailable != null;

  # --- Labels ---
  baseSelectorLabels = {
    "app.kubernetes.io/instance" = scope.instanceName;
    "app.kubernetes.io/name" = "coredns";
  };

  selectorLabels =
    baseSelectorLabels // lib.optionalAttrs cfg.isClusterService { "k8s-app" = "coredns"; };

  labels =
    selectorLabels
    // {
      "app.kubernetes.io/managed-by" = "kix";
    }
    // lib.optionalAttrs cfg.isClusterService {
      "kubernetes.io/cluster-service" = "true";
      "kubernetes.io/name" = "CoreDNS";
    };

in self: {

  # ── Configuration ──────────────────────────────────────────────

  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    data = {
      Corefile = corefile;
    }
    // builtins.listToAttrs (
      map (zf: {
        name = zf.filename;
        value = zf.contents;
      }) cfg.zoneFiles
    );
  };

  # ── RBAC ───────────────────────────────────────────────────────

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "endpoints" "services" "pods" "namespaces" ];
        verbs = [ "list" "watch" ];
      }
      {
        apiGroups = [ "discovery.k8s.io" ];
        resources = [ "endpointslices" ];
        verbs = [ "list" "watch" ];
      }
    ];
  };

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.clusterRole}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "${self.serviceAccount}";
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-coredns";
    inherit labels;
  };

  # ── Workload ───────────────────────────────────────────────────

  workload = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-coredns";
    labels = labels // {
      "app.kubernetes.io/version" = cfg.image.tag;
    };
    requires = [
      self.clusterRoleBinding
    ]
    ++ lib.optional cfg.serviceAccount.create self.serviceAccount
    ++ lib.optional pdbEnabled self.pdb
    ++ lib.optional cfg.hpa.enabled self.hpa
    ++ lib.optional (hasPrometheus && cfg.prometheus.service.enabled) self.metricsService
    ++ lib.optional cfg.autoscaler.enabled self.autoscalerWorkload;
    spec = {
      replicas = if cfg.hpa.enabled || cfg.autoscaler.enabled then null else cfg.replicaCount;
      selector.matchLabels = selectorLabels;
      strategy = {
        type = "RollingUpdate";
        rollingUpdate = {
          maxUnavailable = 1;
          maxSurge = "25%";
        };
      };
      template = {
        metadata = {
          inherit labels;
          annotations = lib.optionalAttrs cfg.isClusterService {
            "scheduler.alpha.kubernetes.io/tolerations" =
              ''[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'';
          };
        };
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          terminationGracePeriodSeconds = 30;
          containers = [
            ({
              name = "coredns";
              image = imageRef;
              imagePullPolicy = cfg.image.pullPolicy;
              args = [ "-conf" "/etc/coredns/Corefile" ];
              inherit (cfg) resources securityContext;
              ports = ports.containerPorts;
              volumeMounts = [
                {
                  name = "config-volume";
                  mountPath = "/etc/coredns";
                }
              ];
            }
            // lib.optionalAttrs cfg.livenessProbe.enabled {
              livenessProbe = {
                httpGet = {
                  path = "/health";
                  port = 8080;
                  scheme = "HTTP";
                };
                inherit (cfg.livenessProbe)
                  initialDelaySeconds
                  periodSeconds
                  timeoutSeconds
                  failureThreshold
                  successThreshold
                  ;
              };
            }
            // lib.optionalAttrs cfg.readinessProbe.enabled {
              readinessProbe = {
                httpGet = {
                  path = "/ready";
                  port = 8181;
                  scheme = "HTTP";
                };
                inherit (cfg.readinessProbe)
                  initialDelaySeconds
                  periodSeconds
                  timeoutSeconds
                  failureThreshold
                  successThreshold
                  ;
              };
            })
          ];
          volumes = [
            {
              name = "config-volume";
              configMap = {
                name = "${self.configmap}";
                items = [
                  { key = "Corefile"; path = "Corefile"; }
                ]
                ++ map (zf: {
                  key = zf.filename;
                  path = zf.filename;
                }) cfg.zoneFiles;
              };
            }
          ];
        }
        // lib.optionalAttrs cfg.isClusterService {
          dnsPolicy = "Default";
        };
      };
    };
  };

  # ── PDB (conditional) ──────────────────────────────────────────

  pdb = scope.mkResource {
    apiVersion = "policy/v1";
    kind = "PodDisruptionBudget";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    spec = {
      selector.matchLabels = selectorLabels;
    }
    // lib.optionalAttrs (cfg.podDisruptionBudget.minAvailable != null) {
      minAvailable = cfg.podDisruptionBudget.minAvailable;
    }
    // lib.optionalAttrs (cfg.podDisruptionBudget.maxUnavailable != null) {
      maxUnavailable = cfg.podDisruptionBudget.maxUnavailable;
    };
  };

  # ── HPA (conditional) ──────────────────────────────────────────

  hpa = if cfg.hpa.enabled then scope.mkResource {
    apiVersion = "autoscaling/v2";
    kind = "HorizontalPodAutoscaler";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    spec = {
      scaleTargetRef = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${self.workload}";
      };
      inherit (cfg.hpa) minReplicas maxReplicas metrics;
    };
  } else null;

  # ── Metrics Service (conditional) ──────────────────────────────

  metricsService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${scope.instanceName}-coredns-metrics";
    labels = labels // {
      "app.kubernetes.io/component" = "metrics";
    };
    annotations = cfg.prometheus.service.annotations;
    outputs = {
      port = "9153";
    };
    spec = {
      selector = selectorLabels;
      ports = [
        {
          name = "metrics";
          port = 9153;
          protocol = "TCP";
          targetPort = 9153;
        }
      ];
    };
  };

  # ── Autoscaler (conditional) ───────────────────────────────────

  autoscalerSelectorLabels = {
    "app.kubernetes.io/instance" = scope.instanceName;
    "app.kubernetes.io/name" = "coredns-autoscaler";
    "k8s-app" = "coredns-autoscaler";
  };

  autoscalerLabels =
    self.autoscalerSelectorLabels
    // {
      "app.kubernetes.io/managed-by" = "kix";
    }
    // lib.optionalAttrs cfg.isClusterService {
      "kubernetes.io/cluster-service" = "true";
      "kubernetes.io/name" = "CoreDNS";
    };

  autoscalerConfigmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${scope.instanceName}-coredns-autoscaler";
    labels = self.autoscalerLabels;
    data = {
      linear = builtins.toJSON {
        inherit (cfg.autoscaler)
          coresPerReplica
          nodesPerReplica
          preventSinglePointFailure
          min
          max
          includeUnschedulableNodes
          ;
      };
    };
  };

  autoscalerSa = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-coredns-autoscaler";
    labels = self.autoscalerLabels;
  };

  autoscalerRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-coredns-autoscaler";
    labels = self.autoscalerLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "nodes" ];
        verbs = [ "list" "watch" ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "replicationcontrollers/scale" ];
        verbs = [ "get" "update" ];
      }
      {
        apiGroups = [ "extensions" "apps" ];
        resources = [ "deployments/scale" "replicasets/scale" ];
        verbs = [ "get" "update" ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "configmaps" ];
        verbs = [ "get" "create" ];
      }
    ];
  };

  autoscalerBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-coredns-autoscaler";
    labels = self.autoscalerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.autoscalerRole}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "${self.autoscalerSa}";
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  autoscalerWorkload = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-coredns-autoscaler";
    labels = self.autoscalerLabels;
    spec = {
      replicas = null;
      selector.matchLabels = self.autoscalerSelectorLabels;
      template = {
        metadata = {
          labels = self.autoscalerSelectorLabels;
          annotations = {
            "checksum/configmap" = builtins.hashString "sha256" (
              builtins.toJSON {
                inherit (cfg.autoscaler)
                  coresPerReplica
                  nodesPerReplica
                  preventSinglePointFailure
                  min
                  max
                  includeUnschedulableNodes
                  ;
              }
            );
          }
          // lib.optionalAttrs cfg.isClusterService {
            "scheduler.alpha.kubernetes.io/tolerations" =
              ''[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'';
          };
        };
        spec = {
          serviceAccountName = "${self.autoscalerSa}";
          containers = [
            {
              name = "autoscaler";
              image = "${cfg.autoscaler.image.repository}:${cfg.autoscaler.image.tag}";
              imagePullPolicy = cfg.autoscaler.image.pullPolicy;
              resources = cfg.autoscaler.resources;
              command = [
                "/cluster-proportional-autoscaler"
                "--namespace=${scope.namespaceName}"
                "--configmap=${scope.instanceName}-coredns-autoscaler"
                "--target=Deployment/${scope.instanceName}-coredns"
                "--logtostderr=true"
                "--v=2"
              ];
              livenessProbe = {
                httpGet = {
                  path = "/healthz";
                  port = 8080;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 10;
                periodSeconds = 5;
                timeoutSeconds = 5;
                successThreshold = 1;
                failureThreshold = 3;
              };
            }
          ];
        };
      };
    };
  };

  # ── DNS Service ────────────────────────────────────────────────

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    outputs = {
      dnsPort = "53";
    };
    spec = {
      type = cfg.serviceType;
      selector = selectorLabels;
      ports = ports.servicePorts;
    };
  };

  # ── Main: the public interface ─────────────────────────────────

  main = {
    resource = self.service;
    requires = [ self.workload ];
  };
}
