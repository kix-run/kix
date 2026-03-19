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

  # --- RBAC DSL ---
  inherit (scope.rbac) group core grant full allow sub mkClusterRoleSet mkRoleSet;
  actions   = group "actions.github.com" [ "autoscalingrunnersets" "autoscalinglisteners" "ephemeralrunnersets" "ephemeralrunners" ];
  actionResources = [ actions.autoscalingrunnersets actions.autoscalinglisteners actions.ephemeralrunnersets actions.ephemeralrunners ];
  rbacGroup = group "rbac.authorization.k8s.io" [ "rolebindings" "roles" ];

in
self:
let

  clusterRoles = mkClusterRoleSet scope {
    subjects = [{ kind = "ServiceAccount"; name = self.serviceAccount.out.name; namespace = scope.namespaceName; }];
    roles = {
      "${controllerName}" = grant [
        ([core.pods core.serviceaccounts]          |> allow [ "list" "watch" ])
        (actionResources                           |> full)
        (map (sub "finalizers") actionResources    |> allow [ "patch" "update" ])
        (map (sub "status") actionResources        |> allow [ "get" "patch" "update" ])
        (rbacGroup.rolebindings                    |> allow [ "list" "watch" ])
        (rbacGroup.roles                           |> allow [ "list" "watch" "patch" ])
      ];
    };
  };

  nsRoles = mkRoleSet scope {
    subjects = [{ kind = "ServiceAccount"; name = self.serviceAccount.out.name; namespace = scope.namespaceName; }];
    roles = {
      "${controllerName}-listener" = grant [
        (core.pods              |> allow [ "create" "delete" "get" ])
        (core "pods/status"     |> allow [ "get" ])
        (core.secrets           |> allow [ "create" "delete" "get" "patch" "update" ])
        (core.serviceaccounts   |> allow [ "create" "delete" "get" "patch" "update" ])
      ];
    };
  };

in {

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
          serviceAccountName = self.serviceAccount.out.name;
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
  main = self.deployment;
} // clusterRoles // nsRoles
