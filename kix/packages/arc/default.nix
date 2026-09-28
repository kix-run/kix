# GitHub Actions Runner Controller (ARC) package.
#
# Deploys the gha-runner-scale-set-controller which manages
# AutoScalingRunnerSets and EphemeralRunners for GitHub Actions
# self-hosted runners.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding,
#            Role (listener), RoleBinding, Deployment,
#            4 CustomResourceDefinitions (actions.github.com).
#
# root = Deployment (gha-rs-controller)

{
  scope,
  lib,
  kix,
  availability,
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
  meta = {
    version = "0.13.1";
    description = "GitHub Actions Runner Controller (gha-runner-scale-set-controller), which runs self-hosted runner scale sets";
    owner = "platform";
    # The controller runs without leader election here (no lease RBAC), so
    # one replica is the ceiling it can honour.
    availability.max = "pod";
  };

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
      # Fixed at 1: a second controller would reconcile every runner scale
      # set twice. See meta.availability.max.
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

      # --- CRDs ---
      # Vendored verbatim from the gha-runner-scale-set-controller chart at the
      # tag matching config.image.tag:
      #   https://github.com/actions/actions-runner-controller/tree/gha-runner-scale-set-0.13.1/charts/gha-runner-scale-set-controller/crds
      # Without them the controller crash-loops on start with
      # `no matches for kind "EphemeralRunnerSet" in version
      # "actions.github.com/v1alpha1"`.
      crds =
        let
          vendored = file: (builtins.fromJSON (builtins.readFile ./crds/${file})).spec;
        in
        {
          autoscalingListeners = scope.mkCRD {
            spec = vendored "autoscalinglisteners.actions.github.com.json";
          };
          autoscalingRunnerSets = scope.mkCRD {
            spec = vendored "autoscalingrunnersets.actions.github.com.json";
          };
          ephemeralRunners = scope.mkCRD {
            spec = vendored "ephemeralrunners.actions.github.com.json";
          };
          ephemeralRunnerSets = scope.mkCRD {
            spec = vendored "ephemeralrunnersets.actions.github.com.json";
          };
        };

      # --- Deployment (gha-rs-controller) ---
      deployment = scope.mkDeployment {
        name = controllerName;
        # The API group this controller reconciles must exist before it starts.
        requires = builtins.attrValues self.crds;
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
            metadata = {
              labels = templateLabels;
              annotations = {
                "kubectl.kubernetes.io/default-container" = "manager";
              };
            };
            spec = {
              serviceAccount = self.serviceAccount;
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
                  # The 0.13.1 manager has no health endpoints: the
                  # `--health-probe-bind-address` flag first ships in
                  # gha-runner-scale-set 0.14.2, and 0.13.1 exits on it.
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
                  # The image runs as 65532. The chart (0.13.1) mounts the
                  # /tmp emptyDir below and suggests a read-only root in its
                  # `securityContext` example.
                  securityContext = {
                    runAsNonRoot = true;
                    readOnlyRootFilesystem = true;
                  };
                  volumeMounts = [
                    {
                      name = "tmp";
                      mountPath = "/tmp";
                    }
                  ];
                }
              ];
              volumes = [
                # An empty emptyDir is a source, not an absence: kept so the
                # collapse rule does not render a volume without one.
                {
                  name = "tmp";
                  emptyDir = kix.keep { };
                }
              ];
            };
          };
        };
      };

      # --- Entry point ---
      root = {
        resource = self.deployment;
        requires = [
          self.serviceAccount
        ]
        ++ builtins.attrValues self.crds;
      };
    }
    // clusterRoles
    // nsRoles;
}
