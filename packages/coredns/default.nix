# CoreDNS kix package.
#
# Produces: ConfigMap, Deployment, Service (kube-dns), ServiceAccount,
# ClusterRole, ClusterRoleBinding, and optionally HPA, PDB, metrics
# Service, and ServiceMonitor.
#
# main = Service (kube-dns), selecting the Deployment via .out.selector.

{
  scope,
  lib,
}:

let
  helpers = import ./helpers.nix { inherit lib; };

  # Selector labels — used for Deployment matchLabels and template labels.
  # Other resources derive selectors via .out.selector.
  selectorLabels = {
    "k8s-app" = "coredns";
    "app.kubernetes.io/name" = "coredns";
  };

  # RBAC DSL
  inherit (scope.rbac) grant allow core;
  discovery = scope.rbac.group "discovery.k8s.io" [ "endpointslices" ];

in
{
  options = {
    image = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        repository = "coredns/coredns";
        tag = "1.13.1";
        pullPolicy = "IfNotPresent";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    isClusterService = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    serviceType = lib.mkOption {
      type = lib.types.str;
      default = "ClusterIP";
    };
    clusterIP = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Explicit ClusterIP for the kube-dns service";
    };
    serviceAccount = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        create = true;
        name = null;
      };
    };
    servers = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ helpers.defaultServer ];
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "100m";
          memory = "128Mi";
        };
      };
    };
    rollingUpdate = lib.mkOption {
      type = lib.types.anything;
      default = {
        maxSurge = "25%";
        maxUnavailable = 1;
      };
    };
    affinity = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
    };
    enableTcpPort = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    hpa = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        minReplicas = 1;
        maxReplicas = 5;
        metrics = [ ];
      };
    };
    podDisruptionBudget = lib.mkOption {
      type = lib.types.anything;
      default = {
        minAvailable = null;
        maxUnavailable = null;
      };
    };
    prometheus = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        service = {
          enabled = false;
          annotations = { };
        };
        monitor = {
          enabled = false;
          interval = null;
        };
      };
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      # Whether PDB is enabled: at least one of minAvailable/maxUnavailable is set.
      pdbEnabled =
        config.podDisruptionBudget.minAvailable != null
        || config.podDisruptionBudget.maxUnavailable != null;

      # Common labels applied to all resources.
      commonLabels =
        selectorLabels
        // lib.optionalAttrs config.isClusterService {
          "kubernetes.io/cluster-service" = "true";
          "kubernetes.io/name" = "CoreDNS";
        };

      # Build the Corefile string from server config.
      corefile = helpers.mkCorefile config.servers;

      saName =
        if config.serviceAccount.name != null then config.serviceAccount.name else scope.instanceName;

      serviceMonitorCRDRef = scope.mkCRDRef {
        group = "monitoring.coreos.com";
        kind = "ServiceMonitor";
        plural = "servicemonitors";
      };
      mkServiceMonitor = serviceMonitorCRDRef.out.mkCR scope;

    in
    {

      # --- ServiceAccount ---
      serviceAccount =
        if config.serviceAccount.create then
          scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = saName;
            labels = commonLabels;
          }
        else
          null;

      # --- ConfigMap (Corefile) ---
      configmap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${scope.instanceName}";
        labels = {
          "app.kubernetes.io/name" = "coredns";
        };
        data = {
          Corefile = corefile;
        };
      };

    }
    // scope.rbac.mkClusterRoleSet scope {
      subjects = [
        {
          kind = "ServiceAccount";
          name = self.serviceAccount.out.name;
          namespace = scope.namespaceName;
        }
      ];
      labels = commonLabels;
      roles = {
        "${scope.instanceName}" = grant [
          (
            [
              core.endpoints
              core.services
              core.pods
              core.namespaces
              discovery.endpointslices
            ]
            |> allow [
              "list"
              "watch"
            ]
          )
        ];
      };
    }
    // {

      # --- Deployment ---
      deployment = scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${scope.instanceName}";
        labels = commonLabels // {
          "app.kubernetes.io/version" = config.image.tag;
        };
        spec = {
          replicas = config.replicaCount;
          strategy = {
            type = "RollingUpdate";
            rollingUpdate = {
              inherit (config.rollingUpdate) maxUnavailable maxSurge;
            };
          };
          selector.matchLabels = selectorLabels // {
            "app.kubernetes.io/instance" = scope.instanceName;
          };
          template = {
            metadata = {
              labels = selectorLabels // {
                "app.kubernetes.io/instance" = scope.instanceName;
              };
              annotations = {
                "scheduler.alpha.kubernetes.io/tolerations" =
                  ''[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'';
              };
            };
            spec = {
              terminationGracePeriodSeconds = 30;
              serviceAccountName = self.serviceAccount.out.name;
              dnsPolicy = "Default";
            }
            // lib.optionalAttrs (config.affinity != null) {
              inherit (config) affinity;
            }
            // {
              containers = [
                {
                  name = "coredns";
                  image = "${config.image.repository}:${config.image.tag}";
                  imagePullPolicy = config.image.pullPolicy;
                  args = [
                    "-conf"
                    "/etc/coredns/Corefile"
                  ];
                  volumeMounts = [
                    {
                      name = "config-volume";
                      mountPath = "/etc/coredns";
                    }
                  ];
                  inherit (config) resources;
                  ports = [
                    {
                      containerPort = 53;
                      name = "udp-53";
                      protocol = "UDP";
                    }
                  ]
                  ++ lib.optional config.enableTcpPort {
                    containerPort = 53;
                    name = "tcp-53";
                    protocol = "TCP";
                  }
                  ++ [
                    {
                      containerPort = 9153;
                      name = "tcp-9153";
                      protocol = "TCP";
                    }
                  ];
                  livenessProbe = {
                    httpGet = {
                      path = "/health";
                      port = 8080;
                      scheme = "HTTP";
                    };
                    initialDelaySeconds = 60;
                    periodSeconds = 10;
                    timeoutSeconds = 5;
                    successThreshold = 1;
                    failureThreshold = 5;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/ready";
                      port = 8181;
                      scheme = "HTTP";
                    };
                    initialDelaySeconds = 30;
                    periodSeconds = 5;
                    timeoutSeconds = 5;
                    successThreshold = 1;
                    failureThreshold = 1;
                  };
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities = {
                      add = [ "NET_BIND_SERVICE" ];
                      drop = [ "ALL" ];
                    };
                    readOnlyRootFilesystem = true;
                  };
                }
              ];
              volumes = [
                {
                  name = "config-volume";
                  configMap = {
                    name = self.configmap.out.name;
                    defaultMode = 420;
                    items = [
                      {
                        key = "Corefile";
                        path = "Corefile";
                      }
                    ];
                  };
                }
              ];
            };
          };
        };
      };

      # --- Service (kube-dns) ---
      service = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${scope.instanceName}";
        labels = commonLabels;
        spec = {
          selector = self.deployment.out.selector;
          ports = [
            {
              name = "udp-53";
              port = 53;
              protocol = "UDP";
              targetPort = 53;
            }
          ]
          ++ lib.optional config.enableTcpPort {
            name = "tcp-53";
            port = 53;
            protocol = "TCP";
            targetPort = 53;
          };
          type = config.serviceType;
        }
        // lib.optionalAttrs (config.clusterIP != null) {
          clusterIP = config.clusterIP;
        };
        requires =
          lib.optional (self.metricsService != null) self.metricsService
          ++ lib.optional (self.serviceMonitor != null) self.serviceMonitor
          ++ lib.optional (self.hpa != null) self.hpa
          ++ lib.optional (self.pdb != null) self.pdb;
      };

      # --- Optional: Metrics Service ---
      metricsService =
        if config.prometheus.service.enabled or false then
          scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "${scope.instanceName}-metrics";
            labels = commonLabels // {
              "app.kubernetes.io/component" = "metrics";
            };
            annotations = config.prometheus.service.annotations or { };
            spec = {
              selector = self.deployment.out.selector;
              ports = [
                {
                  name = "metrics";
                  port = 9153;
                  protocol = "TCP";
                  targetPort = 9153;
                }
              ];
              type = "ClusterIP";
            };
          }
        else
          null;

      # --- Optional: ServiceMonitor ---
      serviceMonitor =
        if config.prometheus.monitor.enabled or false then
          mkServiceMonitor {
            name = "${scope.instanceName}";
            labels = commonLabels;
            spec = {
              namespaceSelector.matchNames = [ scope.namespaceName ];
              selector.matchLabels = self.metricsService.out.selector;
              endpoints = [
                (
                  {
                    port = "metrics";
                  }
                  // lib.optionalAttrs (config.prometheus.monitor.interval != null) {
                    interval = config.prometheus.monitor.interval;
                  }
                )
              ];
            };
          }
        else
          null;

      # --- Optional: HPA ---
      hpa =
        if config.hpa.enabled then
          scope.mkResource {
            apiVersion = "autoscaling/v2";
            kind = "HorizontalPodAutoscaler";
            name = "${scope.instanceName}";
            labels = commonLabels;
            spec = {
              scaleTargetRef = {
                apiVersion = "apps/v1";
                kind = "Deployment";
                name = self.deployment.out.name;
              };
              minReplicas = config.hpa.minReplicas;
              maxReplicas = config.hpa.maxReplicas;
              metrics = config.hpa.metrics;
            };
          }
        else
          null;

      # --- Optional: PDB ---
      pdb =
        if pdbEnabled then
          scope.mkResource {
            apiVersion = "policy/v1";
            kind = "PodDisruptionBudget";
            name = "${scope.instanceName}";
            labels = commonLabels;
            spec = {
              selector.matchLabels = self.deployment.out.selector;
            }
            // lib.optionalAttrs (config.podDisruptionBudget.minAvailable != null) {
              minAvailable = config.podDisruptionBudget.minAvailable;
            }
            // lib.optionalAttrs (config.podDisruptionBudget.maxUnavailable != null) {
              maxUnavailable = config.podDisruptionBudget.maxUnavailable;
            };
          }
        else
          null;

      # --- Entry point ---
      # main is the Service. The Deployment is tracked via .out.selector,
      # ConfigMap and ServiceAccount via .out.name.
      # RBAC is pulled in via inverse dependency detection.
      main = self.service;
    };
}
