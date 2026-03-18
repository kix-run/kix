# CoreDNS kix package.
#
# Produces: ConfigMap, Deployment, Service (kube-dns), ServiceAccount,
# ClusterRole, ClusterRoleBinding, and optionally HPA, PDB, metrics
# Service, and ServiceMonitor.
#
# main = Service (kube-dns), with requires pointing to the Deployment.

{
  scope,
  config,
  lib,
}:

let
  helpers = import ./helpers.nix { inherit lib; };

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
      create = true;
    };
    servers = [ helpers.defaultServer ];
    resources = {
      requests = {
        cpu = "100m";
        memory = "128Mi";
      };
      limits = {
        cpu = "100m";
        memory = "128Mi";
      };
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

  # Whether PDB is enabled: at least one of minAvailable/maxUnavailable is set.
  pdbEnabled =
    cfg.podDisruptionBudget.minAvailable != null || cfg.podDisruptionBudget.maxUnavailable != null;

  # Common labels applied to all resources.
  commonLabels = {
    "k8s-app" = "coredns";
    "app.kubernetes.io/name" = "coredns";
  }
  // lib.optionalAttrs cfg.isClusterService {
    "kubernetes.io/cluster-service" = "true";
    "kubernetes.io/name" = "CoreDNS";
  };

  # Selector labels (subset used in matchLabels and service selectors).
  selectorLabels = {
    "k8s-app" = "coredns";
    "app.kubernetes.io/name" = "coredns";
  };

  # Build the Corefile string from server config.
  corefile = helpers.mkCorefile cfg.servers;

in
self: {

  # --- ServiceAccount ---
  serviceAccount =
    if cfg.serviceAccount.create then
      scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${scope.instanceName}";
        labels = commonLabels;
      }
    else
      null;

  # --- ConfigMap (Corefile) ---
  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${scope.instanceName}";
    labels = commonLabels;
    data = {
      Corefile = corefile;
    };
  };

  # --- ClusterRole ---
  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}";
    labels = commonLabels;
    extra = {
      rules = [
        {
          apiGroups = [ "" ];
          resources = [
            "endpoints"
            "services"
            "pods"
            "namespaces"
          ];
          verbs = [
            "list"
            "watch"
          ];
        }
        {
          apiGroups = [ "discovery.k8s.io" ];
          resources = [ "endpointslices" ];
          verbs = [
            "list"
            "watch"
          ];
        }
      ];
    };
  };

  # --- ClusterRoleBinding ---
  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}";
    labels = commonLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.clusterRole}";
      };
      subjects = [
        ({
          kind = "ServiceAccount";
          name = "${self.serviceAccount}";
          namespace = scope.namespaceName;
        })
      ];
    };
  };

  # --- Deployment ---
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}";
    labels = commonLabels // {
      "app.kubernetes.io/version" = cfg.image.tag;
    };
    spec = {
      replicas = cfg.replicaCount;
      strategy = {
        type = "RollingUpdate";
        rollingUpdate = {
          maxUnavailable = 1;
          maxSurge = "25%";
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
          serviceAccountName = "${self.serviceAccount}";
          dnsPolicy = "Default";
          containers = [
            {
              name = "coredns";
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
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
              inherit (cfg) resources;
              ports = [
                {
                  containerPort = 53;
                  name = "udp-53";
                  protocol = "UDP";
                }
                {
                  containerPort = 53;
                  name = "tcp-53";
                  protocol = "TCP";
                }
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
                name = "${self.configmap}";
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
      selector = selectorLabels // {
        "app.kubernetes.io/instance" = scope.instanceName;
      };
      ports = [
        {
          name = "udp-53";
          port = 53;
          protocol = "UDP";
          targetPort = 53;
        }
        {
          name = "tcp-53";
          port = 53;
          protocol = "TCP";
          targetPort = 53;
        }
      ];
      type = cfg.serviceType;
    };
    requires = [ self.deployment ];
  };

  # --- Optional: Metrics Service ---
  metricsService =
    if cfg.prometheus.service.enabled or false then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${scope.instanceName}-metrics";
        labels = commonLabels // {
          "app.kubernetes.io/component" = "metrics";
        };
        annotations = cfg.prometheus.service.annotations or { };
        spec = {
          selector = selectorLabels // {
            "app.kubernetes.io/instance" = scope.instanceName;
          };
          ports = [
            {
              name = "metrics";
              port = 9153;
              targetPort = 9153;
            }
          ];
        };
        requires = [ self.deployment ];
      }
    else
      null;

  # --- Optional: ServiceMonitor ---
  serviceMonitor =
    if cfg.prometheus.monitor.enabled or false then
      scope.mkClusterResource {
        apiVersion = "monitoring.coreos.com/v1";
        kind = "ServiceMonitor";
        name = "${scope.instanceName}";
        labels = commonLabels;
        spec = {
          namespaceSelector.matchNames = [ scope.namespaceName ];
          selector.matchLabels = selectorLabels // {
            "app.kubernetes.io/instance" = scope.instanceName;
            "app.kubernetes.io/component" = "metrics";
          };
          endpoints = [
            (
              {
                port = "metrics";
              }
              // lib.optionalAttrs (cfg.prometheus.monitor.interval != null) {
                interval = cfg.prometheus.monitor.interval;
              }
            )
          ];
        };
      }
    else
      null;

  # --- Optional: HPA ---
  hpa =
    if cfg.hpa.enabled then
      scope.mkResource {
        apiVersion = "autoscaling/v2";
        kind = "HorizontalPodAutoscaler";
        name = "${scope.instanceName}";
        labels = commonLabels;
        spec = {
          scaleTargetRef = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "${self.deployment}";
          };
          minReplicas = cfg.hpa.minReplicas;
          maxReplicas = cfg.hpa.maxReplicas;
          metrics = cfg.hpa.metrics;
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
          selector.matchLabels = selectorLabels // {
            "app.kubernetes.io/instance" = scope.instanceName;
          };
        }
        // lib.optionalAttrs (cfg.podDisruptionBudget.minAvailable != null) {
          minAvailable = cfg.podDisruptionBudget.minAvailable;
        }
        // lib.optionalAttrs (cfg.podDisruptionBudget.maxUnavailable != null) {
          maxUnavailable = cfg.podDisruptionBudget.maxUnavailable;
        };
      }
    else
      null;

  # --- Entry point ---
  # main is the Service. It `requires` the Deployment, which in turn
  # references the ConfigMap and ServiceAccount via ${} interpolation.
  # The ClusterRoleBinding references both ClusterRole and ServiceAccount.
  main = self.service;
}
