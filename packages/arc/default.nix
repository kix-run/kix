# GitHub Actions Runner Controller (ARC) package.
#
# Deploys the gha-runner-scale-set-controller which manages
# AutoScalingRunnerSets and EphemeralRunners for GitHub Actions
# self-hosted runners.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding,
#            Role (leader election), RoleBinding, Deployment.
#
# main = Deployment (controller-manager)

{
  scope,
  config,
  lib,
}:

let
  name = scope.instanceName;

  cfg = scope.defaults config {
    image = {
      repository = "ghcr.io/actions/gha-runner-scale-set-controller";
      tag = "0.11.0";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 1;
    resources = {
      requests = {
        cpu = "200m";
        memory = "256Mi";
      };
      limits = {
        cpu = "1";
        memory = "512Mi";
      };
    };
    leaderElection = true;
  };

  selectorLabels = {
    "app.kubernetes.io/name" = "arc";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "controller-manager";
  };

in
self: {

  # --- ServiceAccount ---
  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}-controller-manager";
    labels = selectorLabels;
  };

  # --- ClusterRole ---
  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-manager-role";
    labels = selectorLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [
          "pods"
          "pods/status"
        ];
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
        resources = [
          "secrets"
          "serviceaccounts"
        ];
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
      {
        apiGroups = [ "" ];
        resources = [ "namespaces" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "actions.github.com" ];
        resources = [
          "autoscalingrunnersets"
          "autoscalingrunnersets/status"
          "autoscalingrunnersets/finalizers"
          "autoscalinglisteners"
          "autoscalinglisteners/status"
          "autoscalinglisteners/finalizers"
          "ephemeralrunners"
          "ephemeralrunners/status"
          "ephemeralrunners/finalizers"
          "ephemeralrunnersets"
          "ephemeralrunnersets/status"
          "ephemeralrunnersets/finalizers"
        ];
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
        apiGroups = [ "rbac.authorization.k8s.io" ];
        resources = [
          "roles"
          "rolebindings"
        ];
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
    ];
  };

  # --- ClusterRoleBinding ---
  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-manager-rolebinding";
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

  # --- Role (leader election, namespace-scoped) ---
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

  # --- RoleBinding ---
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

  # --- Deployment (controller-manager) ---
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${name}-controller-manager";
    labels = selectorLabels;
    spec = {
      replicas = cfg.replicaCount;
      selector.matchLabels = selectorLabels;
      template = {
        metadata.labels = selectorLabels;
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
                "--auto-scaling-runner-set-only"
                "--log-level=info"
                "--log-format=text"
                "--update-strategy=eventual"
              ]
              ++ lib.optionals cfg.leaderElection [
                "--enable-leader-election"
                "--leader-election-id=${name}-controller"
              ];
              env = [
                {
                  name = "CONTROLLER_MANAGER_CONTAINER_IMAGE";
                  value = "${cfg.image.repository}:${cfg.image.tag}";
                }
                {
                  name = "CONTROLLER_MANAGER_POD_NAMESPACE";
                  valueFrom.fieldRef.fieldPath = "metadata.namespace";
                }
              ];
              ports = [
                {
                  name = "metrics";
                  containerPort = 8080;
                  protocol = "TCP";
                }
                {
                  name = "health";
                  containerPort = 8081;
                  protocol = "TCP";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/healthz";
                  port = "health";
                };
                initialDelaySeconds = 15;
                periodSeconds = 20;
                timeoutSeconds = 3;
                failureThreshold = 3;
                successThreshold = 1;
              };
              readinessProbe = {
                httpGet = {
                  path = "/readyz";
                  port = "health";
                };
                initialDelaySeconds = 5;
                periodSeconds = 10;
                timeoutSeconds = 3;
                failureThreshold = 3;
                successThreshold = 1;
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

  # --- Entry point ---
  main = {
    resource = self.deployment;
    requires = [
      self.serviceAccount
      self.clusterRole
      self.clusterRoleBinding
      self.leaderElectionRole
      self.leaderElectionRoleBinding
    ];
  };
}
