# GitHub Actions Runner Controller (ARC) package.
#
# Deploys the gha-runner-scale-set-controller which manages
# AutoScalingRunnerSets and EphemeralRunners for GitHub Actions
# self-hosted runners.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding,
#            Role (listener), RoleBinding, Deployment.
#
# main = Deployment (gha-rs-controller)

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
      tag = "0.13.1";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 1;
    releaseName = "${name}-controller";
    logLevel = "debug";
    logFormat = "text";
    updateStrategy = "immediate";
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
  };

  controllerName = "${cfg.releaseName}-gha-rs-controller";

  selectorLabels = {
    "app.kubernetes.io/name" = "gha-rs-controller";
    "app.kubernetes.io/instance" = cfg.releaseName;
    "app.kubernetes.io/namespace" = scope.namespaceName;
  };

  templateLabels = selectorLabels // {
    "app.kubernetes.io/component" = "controller-manager";
    "app.kubernetes.io/part-of" = "gha-rs-controller";
    "app.kubernetes.io/version" = cfg.image.tag;
  };

in
self: {

  # --- ServiceAccount ---
  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = controllerName;
    labels = selectorLabels // {
      "app.kubernetes.io/part-of" = "gha-rs-controller";
      "app.kubernetes.io/version" = cfg.image.tag;
    };
  };

  # --- ClusterRole ---
  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = controllerName;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "pods" ];
        verbs = [
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "serviceaccounts" ];
        verbs = [
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "actions.github.com" ];
        resources = [ "autoscalingrunnersets" ];
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
        apiGroups = [ "actions.github.com" ];
        resources = [ "autoscalingrunnersets/finalizers" ];
        verbs = [
          "patch"
          "update"
        ];
      }
      {
        apiGroups = [ "actions.github.com" ];
        resources = [ "autoscalingrunnersets/status" ];
        verbs = [
          "get"
          "patch"
          "update"
        ];
      }
      {
        apiGroups = [ "actions.github.com" ];
        resources = [ "autoscalinglisteners" ];
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
        apiGroups = [ "actions.github.com" ];
        resources = [ "autoscalinglisteners/status" ];
        verbs = [
          "get"
          "patch"
          "update"
        ];
      }
      {
        apiGroups = [ "actions.github.com" ];
        resources = [ "autoscalinglisteners/finalizers" ];
        verbs = [
          "patch"
          "update"
        ];
      }
      {
        apiGroups = [ "actions.github.com" ];
        resources = [ "ephemeralrunnersets" ];
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
        apiGroups = [ "actions.github.com" ];
        resources = [ "ephemeralrunnersets/status" ];
        verbs = [
          "get"
          "patch"
          "update"
        ];
      }
      {
        apiGroups = [ "actions.github.com" ];
        resources = [ "ephemeralrunnersets/finalizers" ];
        verbs = [
          "patch"
          "update"
        ];
      }
      {
        apiGroups = [ "actions.github.com" ];
        resources = [ "ephemeralrunners" ];
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
        apiGroups = [ "actions.github.com" ];
        resources = [ "ephemeralrunners/finalizers" ];
        verbs = [
          "patch"
          "update"
        ];
      }
      {
        apiGroups = [ "actions.github.com" ];
        resources = [ "ephemeralrunners/status" ];
        verbs = [
          "get"
          "patch"
          "update"
        ];
      }
      {
        apiGroups = [ "rbac.authorization.k8s.io" ];
        resources = [ "rolebindings" ];
        verbs = [
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "rbac.authorization.k8s.io" ];
        resources = [ "roles" ];
        verbs = [
          "list"
          "watch"
          "patch"
        ];
      }
    ];
  };

  # --- ClusterRoleBinding ---
  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = controllerName;
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

  # --- Role (listener, namespace-scoped) ---
  listenerRole = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${controllerName}-listener";
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "pods" ];
        verbs = [
          "create"
          "delete"
          "get"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "pods/status" ];
        verbs = [ "get" ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "create"
          "delete"
          "get"
          "patch"
          "update"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "serviceaccounts" ];
        verbs = [
          "create"
          "delete"
          "get"
          "patch"
          "update"
        ];
      }
    ];
  };

  # --- RoleBinding ---
  listenerRoleBinding = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${controllerName}-listener";
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.listenerRole}";
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

  # --- Deployment (gha-rs-controller) ---
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = controllerName;
    labels = {
      "actions.github.com/controller-service-account-name" = controllerName;
      "actions.github.com/controller-service-account-namespace" = scope.namespaceName;
    } // selectorLabels // {
      "app.kubernetes.io/part-of" = "gha-rs-controller";
      "app.kubernetes.io/version" = cfg.image.tag;
    };
    spec = {
      replicas = cfg.replicaCount;
      selector.matchLabels = selectorLabels;
      template = {
        metadata.labels = templateLabels;
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          terminationGracePeriodSeconds = 10;
          containers = [
            {
              name = "manager";
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              command = [ "/manager" ];
              args = [
                "--auto-scaling-runner-set-only"
                "--log-level=${cfg.logLevel}"
                "--log-format=${cfg.logFormat}"
                "--runner-max-concurrent-reconciles=2"
                "--update-strategy=${cfg.updateStrategy}"
                "--listener-metrics-addr=0"
                "--listener-metrics-endpoint="
                "--metrics-addr=0"
              ];
              env = [
                {
                  name = "CONTROLLER_MANAGER_CONTAINER_IMAGE";
                  value = "${cfg.image.repository}:${cfg.image.tag}";
                }
                {
                  name = "CONTROLLER_MANAGER_POD_NAMESPACE";
                  valueFrom.fieldRef = {
                    apiVersion = "v1";
                    fieldPath = "metadata.namespace";
                  };
                }
              ];
              resources = cfg.resources;
              volumeMounts = [
                {
                  name = "tmp";
                  mountPath = "/tmp";
                }
              ];
            }
          ];
          volumes = [
            { name = "tmp"; }
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
      self.listenerRole
      self.listenerRoleBinding
    ];
  };
}
