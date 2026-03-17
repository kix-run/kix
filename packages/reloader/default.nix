# Reloader package — stakater/reloader.
#
# Watches ConfigMaps and Secrets for changes and triggers rolling
# restarts on Deployments, DaemonSets, and StatefulSets that
# reference them.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding,
#            Deployment, Service (metrics).

{
  scope,
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    image = {
      repository = "ghcr.io/stakater/reloader";
      tag = "v1.3.0";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 1;
    logFormat = "json";
    resources = {
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

  name = scope.instanceName;

  selectorLabels = {
    "app.kubernetes.io/name" = "reloader";
    "app.kubernetes.io/instance" = name;
  };

in
self: {

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

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-reloader";
    labels = selectorLabels;
    spec = {
      type = "ClusterIP";
      selector = selectorLabels;
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
  };

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${name}-reloader";
    labels = selectorLabels;
    spec = {
      replicas = cfg.replicaCount;
      revisionHistoryLimit = 2;
      selector.matchLabels = selectorLabels;
      template = {
        metadata = {
          labels = selectorLabels;
        };
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          securityContext = {
            runAsNonRoot = true;
            runAsUser = 65534;
            seccompProfile.type = "RuntimeDefault";
          };
          containers = [
            {
              name = "reloader";
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              args = [
                "--log-format=${cfg.logFormat}"
              ];
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
              resources = cfg.resources;
              securityContext = { };
            }
          ];
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
      self.service
    ];
  };
}
