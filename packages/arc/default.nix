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
  lib,
}:

let
  name = scope.instanceName;

  # --- RBAC DSL ---
  inherit (scope.rbac)
    group
    core
    grant
    full
    allow
    sub
    mkClusterRoleSet
    mkRoleSet
    ;
  actions = group "actions.github.com" [
    "autoscalingrunnersets"
    "autoscalinglisteners"
    "ephemeralrunnersets"
    "ephemeralrunners"
  ];
  actionResources = [
    actions.autoscalingrunnersets
    actions.autoscalinglisteners
    actions.ephemeralrunnersets
    actions.ephemeralrunners
  ];
  rbacGroup = group "rbac.authorization.k8s.io" [
    "rolebindings"
    "roles"
  ];

in
{
  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "ghcr.io/actions/gha-runner-scale-set-controller";
        tag = "0.13.1";
        pullPolicy = "IfNotPresent";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    releaseName = lib.mkOption {
      type = lib.types.str;
      default = "${name}-controller";
    };
    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "debug";
    };
    logFormat = lib.mkOption {
      type = lib.types.str;
      default = "text";
    };
    updateStrategy = lib.mkOption {
      type = lib.types.str;
      default = "immediate";
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
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
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      controllerName = "${config.releaseName}-gha-rs-controller";

      selectorLabels = {
        "app.kubernetes.io/name" = "gha-rs-controller";
        "app.kubernetes.io/instance" = config.releaseName;
        "app.kubernetes.io/namespace" = scope.namespaceName;
      };

      templateLabels = selectorLabels // {
        "app.kubernetes.io/component" = "controller-manager";
        "app.kubernetes.io/part-of" = "gha-rs-controller";
        "app.kubernetes.io/version" = config.image.tag;
      };

      clusterRoles = mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];
        roles = {
          "${controllerName}" = grant [
            (
              [
                core.pods
                core.serviceaccounts
              ]
              |> allow [
                "list"
                "watch"
              ]
            )
            (actionResources |> full)
            (
              map (sub "finalizers") actionResources
              |> allow [
                "patch"
                "update"
              ]
            )
            (
              map (sub "status") actionResources
              |> allow [
                "get"
                "patch"
                "update"
              ]
            )
            (
              rbacGroup.rolebindings
              |> allow [
                "list"
                "watch"
              ]
            )
            (
              rbacGroup.roles
              |> allow [
                "list"
                "watch"
                "patch"
              ]
            )
          ];
        };
      };

      nsRoles = mkRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];
        roles = {
          "${controllerName}-listener" = grant [
            (
              core.pods
              |> allow [
                "create"
                "delete"
                "get"
              ]
            )
            (core "pods/status" |> allow [ "get" ])
            (
              core.secrets
              |> allow [
                "create"
                "delete"
                "get"
                "patch"
                "update"
              ]
            )
            (
              core.serviceaccounts
              |> allow [
                "create"
                "delete"
                "get"
                "patch"
                "update"
              ]
            )
          ];
        };
      };

    in
    {

      # --- ServiceAccount ---
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = controllerName;
        labels = selectorLabels // {
          "app.kubernetes.io/part-of" = "gha-rs-controller";
          "app.kubernetes.io/version" = config.image.tag;
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
        }
        // selectorLabels
        // {
          "app.kubernetes.io/part-of" = "gha-rs-controller";
          "app.kubernetes.io/version" = config.image.tag;
        };
        spec = {
          replicas = config.replicaCount;
          selector.matchLabels = selectorLabels;
          template = {
            metadata.labels = templateLabels;
            spec = {
              serviceAccountName = self.serviceAccount.out.name;
              terminationGracePeriodSeconds = 10;
              containers = [
                {
                  name = "manager";
                  image = "${config.image.repository}:${config.image.tag}";
                  imagePullPolicy = config.image.pullPolicy;
                  command = [ "/manager" ];
                  args = [
                    "--auto-scaling-runner-set-only"
                    "--log-level=${config.logLevel}"
                    "--log-format=${config.logFormat}"
                    "--runner-max-concurrent-reconciles=2"
                    "--update-strategy=${config.updateStrategy}"
                    "--listener-metrics-addr=0"
                    "--listener-metrics-endpoint="
                    "--metrics-addr=0"
                  ];
                  env = [
                    {
                      name = "CONTROLLER_MANAGER_CONTAINER_IMAGE";
                      value = "${config.image.repository}:${config.image.tag}";
                    }
                    {
                      name = "CONTROLLER_MANAGER_POD_NAMESPACE";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "metadata.namespace";
                      };
                    }
                  ];
                  resources = config.resources;
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
    }
    // clusterRoles
    // nsRoles;
}
