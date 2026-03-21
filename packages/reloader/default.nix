# Reloader package — stakater/reloader.
#
# Watches ConfigMaps and Secrets for changes and triggers rolling
# restarts on Deployments, DaemonSets, and StatefulSets that
# reference them.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding,
#            Deployment, Service (metrics, optional).

{
  scope,
  lib,
}:

let
  name = scope.instanceName;

  containerName = "${name}-reloader";

  selectorLabels = {
    "app" = containerName;
    "release" = name;
  };

in
{
  options = {
    image = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        repository = "ghcr.io/stakater/reloader";
        tag = "v1.3.0";
        pullPolicy = "IfNotPresent";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    logFormat = lib.mkOption {
      type = lib.types.str;
      default = "json";
    };
    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
    };
    priorityClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "10m";
          memory = "64Mi";
        };
        limits = {
          cpu = "100m";
          memory = "128Mi";
        };
      };
    };
    service = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        enabled = false;
      };
    };
  };

  build = { self, config, clusterConfig }:
  {

    serviceAccount = scope.mkResource {
      apiVersion = "v1";
      kind = "ServiceAccount";
      name = "${name}-reloader";
      labels = selectorLabels;
    };

    clusterRole = scope.mkClusterResource {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "ClusterRole";
      name = "${name}-reloader-role";
      labels = selectorLabels;
      extra.rules = [
        {
          apiGroups = [ "" ];
          resources = [
            "secrets"
            "configmaps"
          ];
          verbs = [
            "list"
            "get"
            "watch"
          ];
        }
        {
          apiGroups = [ "apps" ];
          resources = [
            "deployments"
            "daemonsets"
            "statefulsets"
          ];
          verbs = [
            "list"
            "get"
            "update"
            "patch"
          ];
        }
        {
          apiGroups = [ "batch" ];
          resources = [ "cronjobs" ];
          verbs = [
            "list"
            "get"
          ];
        }
        {
          apiGroups = [ "batch" ];
          resources = [ "jobs" ];
          verbs = [
            "create"
            "delete"
            "list"
            "get"
          ];
        }
        {
          apiGroups = [ "" ];
          resources = [ "events" ];
          verbs = [
            "create"
            "patch"
          ];
        }
      ];
    };

    clusterRoleBinding = scope.mkClusterResource {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "ClusterRoleBinding";
      name = "${name}-reloader-role-binding";
      labels = selectorLabels;
      extra = {
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.clusterRole.out.name;
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];
      };
    };

    service = if config.service.enabled then scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "${name}-reloader";
      labels = selectorLabels;
      spec = {
        type = "ClusterIP";
        selector = self.deployment.out.selector;
        ports = [
          {
            name = "http";
            port = 9090;
            protocol = "TCP";
            targetPort = "http";
          }
        ];
      };
      outputs = {
        metricsPort = "9090";
      };
    } else null;

    deployment = scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "${name}-reloader";
      labels = selectorLabels;
      spec = {
        replicas = config.replicaCount;
        revisionHistoryLimit = 2;
        selector.matchLabels = selectorLabels;
        template = {
          metadata = {
            labels = selectorLabels;
          };
          spec = {
            serviceAccountName = self.serviceAccount.out.name;
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              seccompProfile.type = "RuntimeDefault";
            };
            containers = [
              {
                name = containerName;
                image = "${config.image.repository}:${config.image.tag}";
                imagePullPolicy = config.image.pullPolicy;
                args = lib.optional (config.logFormat != "") "--log-format=${config.logFormat}"
                  ++ lib.optional (config.logLevel != "") "--log-level=${config.logLevel}";
                env = [
                  {
                    name = "GOMAXPROCS";
                    valueFrom.resourceFieldRef = {
                      resource = "limits.cpu";
                      divisor = "1";
                    };
                  }
                  {
                    name = "GOMEMLIMIT";
                    valueFrom.resourceFieldRef = {
                      resource = "limits.memory";
                      divisor = "1";
                    };
                  }
                ];
                ports = [
                  {
                    name = "http";
                    containerPort = 9090;
                    protocol = "TCP";
                  }
                ];
                livenessProbe = {
                  httpGet = {
                    path = "/live";
                    port = "http";
                  };
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                  timeoutSeconds = 5;
                  failureThreshold = 5;
                  successThreshold = 1;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/metrics";
                    port = "http";
                  };
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                  timeoutSeconds = 5;
                  failureThreshold = 5;
                  successThreshold = 1;
                };
                resources = config.resources;
                securityContext = { };
              }
            ];
          } // lib.optionalAttrs (config.priorityClassName != null) {
            priorityClassName = config.priorityClassName;
          };
        };
      };
    };

    main = {
      resource = self.deployment;
      requires = [
        self.serviceAccount
        self.clusterRole
        self.clusterRoleBinding
      ] ++ lib.optional (self.service != null) self.service;
    };
  };
}
