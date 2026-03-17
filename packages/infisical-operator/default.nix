# Infisical Secrets Operator package.
#
# Syncs InfisicalSecret CRDs to Kubernetes Secrets. The operator
# watches for InfisicalSecret, InfisicalDynamicSecret, InfisicalPushSecret,
# and ClusterGenerator custom resources.
#
# Resources: ServiceAccount, ClusterRole (manager + metrics-auth + metrics-reader),
#            ClusterRoleBinding (manager + metrics-auth), Role (leader election),
#            RoleBinding (leader election), Service (metrics), Deployment.

{
  scope,
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    image = {
      repository = "infisical/kubernetes-operator";
      tag = "v0.9.1";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 1;
    resources = {
      requests = {
        cpu = "10m";
        memory = "64Mi";
      };
      limits = {
        cpu = "500m";
        memory = "128Mi";
      };
    };
  };

  name = scope.instanceName;

  selectorLabels = {
    "app.kubernetes.io/name" = "infisical-operator";
    "app.kubernetes.io/instance" = name;
    "control-plane" = "controller-manager";
  };

in
self: {

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}-controller-manager";
    labels = selectorLabels;
  };

  # --- ClusterRoles ---

  managerRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-manager-role";
    labels = selectorLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [
          "configmaps"
          "secrets"
        ];
        verbs = [
          "create"
          "delete"
          "get"
          "list"
          "update"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "pods" ];
        verbs = [
          "get"
          "list"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "serviceaccounts" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "serviceaccounts/token" ];
        verbs = [ "create" ];
      }
      {
        apiGroups = [ "apps" ];
        resources = [
          "daemonsets"
          "deployments"
          "statefulsets"
        ];
        verbs = [
          "get"
          "list"
          "update"
          "watch"
        ];
      }
      {
        apiGroups = [ "authentication.k8s.io" ];
        resources = [ "tokenreviews" ];
        verbs = [ "create" ];
      }
      {
        apiGroups = [ "secrets.infisical.com" ];
        resources = [
          "clustergenerators"
          "infisicaldynamicsecrets"
          "infisicalpushsecrets"
          "infisicalsecrets"
        ];
        verbs = [
          "create"
          "delete"
          "get"
          "list"
          "patch"
          "update"
          "watch"
        ];
      }
      {
        apiGroups = [ "secrets.infisical.com" ];
        resources = [
          "infisicaldynamicsecrets/finalizers"
          "infisicalpushsecrets/finalizers"
          "infisicalsecrets/finalizers"
        ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "secrets.infisical.com" ];
        resources = [
          "infisicaldynamicsecrets/status"
          "infisicalpushsecrets/status"
          "infisicalsecrets/status"
        ];
        verbs = [
          "get"
          "patch"
          "update"
        ];
      }
    ];
  };

  metricsAuthRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-metrics-auth-role";
    labels = selectorLabels;
    extra.rules = [
      {
        apiGroups = [ "authentication.k8s.io" ];
        resources = [ "tokenreviews" ];
        verbs = [ "create" ];
      }
      {
        apiGroups = [ "authorization.k8s.io" ];
        resources = [ "subjectaccessreviews" ];
        verbs = [ "create" ];
      }
    ];
  };

  metricsReaderRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-metrics-reader";
    labels = selectorLabels;
    extra.rules = [
      {
        nonResourceURLs = [ "/metrics" ];
        verbs = [ "get" ];
      }
    ];
  };

  # --- ClusterRoleBindings ---

  managerRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-manager-rolebinding";
    labels = selectorLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.managerRole}";
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

  metricsAuthRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-metrics-auth-rolebinding";
    labels = selectorLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.metricsAuthRole}";
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

  # --- Role + RoleBinding (leader election, namespace-scoped) ---

  leaderElectionRole = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${name}-leader-election-role";
    labels = selectorLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "configmaps" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
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

  leaderElectionRoleBinding = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${name}-leader-election-rolebinding";
    labels = selectorLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.leaderElectionRole}";
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

  # --- Service (metrics) ---

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-metrics-service";
    labels = selectorLabels;
    spec = {
      type = "ClusterIP";
      selector = selectorLabels;
      ports = [
        {
          name = "https";
          port = 8443;
          protocol = "TCP";
          targetPort = 8443;
        }
      ];
    };
    outputs = {
      metricsPort = "8443";
    };
  };

  # --- Deployment ---

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${name}-controller-manager";
    labels = selectorLabels;
    spec = {
      replicas = cfg.replicaCount;
      selector.matchLabels = selectorLabels;
      template = {
        metadata = {
          labels = selectorLabels;
          annotations = {
            "kubectl.kubernetes.io/default-container" = "manager";
          };
        };
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          terminationGracePeriodSeconds = 10;
          securityContext = {
            runAsNonRoot = true;
            seccompProfile.type = "RuntimeDefault";
          };
          containers = [
            {
              name = "manager";
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              command = [ "/manager" ];
              args = [
                "--metrics-bind-address=:8443"
                "--leader-elect"
                "--health-probe-bind-address=:8081"
              ];
              env = [
                {
                  name = "KUBERNETES_CLUSTER_DOMAIN";
                  value = "cluster.local";
                }
              ];
              ports = [
                {
                  name = "metrics";
                  containerPort = 8443;
                }
                {
                  name = "health";
                  containerPort = 8081;
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/healthz";
                  port = 8081;
                };
                initialDelaySeconds = 15;
                periodSeconds = 20;
              };
              readinessProbe = {
                httpGet = {
                  path = "/readyz";
                  port = 8081;
                };
                initialDelaySeconds = 5;
                periodSeconds = 10;
              };
              resources = cfg.resources;
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
                readOnlyRootFilesystem = true;
              };
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
      self.managerRole
      self.metricsAuthRole
      self.metricsReaderRole
      self.managerRoleBinding
      self.metricsAuthRoleBinding
      self.leaderElectionRole
      self.leaderElectionRoleBinding
      self.service
    ];
  };
}
