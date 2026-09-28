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
    version = "0.14.2";
    description = "GitHub Actions Runner Controller (gha-runner-scale-set-controller), which runs self-hosted runner scale sets";
    owner = "platform";
    # The controller runs without leader election here (no lease RBAC), so
    # one replica is the ceiling it can honour.
    availability.max = "pod";
  };

  options = {
    image = kix.options.image {
      repository = "ghcr.io/actions/gha-runner-scale-set-controller";
      tag = "0.14.2";
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
    healthProbePort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      # The port of the chart's `flags.healthProbeBindAddress` example value.
      default = 8081;
      description = ''
        Port the manager serves /healthz and /readyz on, passed as
        `--health-probe-bind-address=:<port>`. The liveness and readiness
        probes target it. `null` omits the flag, which switches the
        endpoints off, and drops both probes.
      '';
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
      healthProbesEnabled = config.healthProbePort != null;

      # Paths and timings from the chart's deployment template (0.14.2),
      # which adds these probes whenever the bind address is set.
      healthProbes = lib.optionalAttrs healthProbesEnabled {
        ports = [ (kix.port "health" config.healthProbePort) ];
        livenessProbe = {
          httpGet = {
            path = "/healthz";
            port = "health";
          };
          initialDelaySeconds = 15;
          periodSeconds = 20;
        };
        readinessProbe = {
          httpGet = {
            path = "/readyz";
            port = "health";
          };
          initialDelaySeconds = 5;
          periodSeconds = 10;
        };
      };

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
      #   https://github.com/actions/actions-runner-controller/tree/gha-runner-scale-set-0.14.2/charts/gha-runner-scale-set-controller/crds
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
                (
                  {
                    name = "manager";
                    image = kix.image.ref config.image;
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
                    ]
                    ++ lib.optional healthProbesEnabled "--health-probe-bind-address=:${toString config.healthProbePort}";
                    env = [
                      {
                        name = "CONTROLLER_MANAGER_CONTAINER_IMAGE";
                        value = kix.image.ref config.image;
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
                    # The image runs as 65532. The chart (0.14.2) mounts the
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
                  // healthProbes
                )
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
