# Reloader package: stakater/reloader.
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
  kix,
  availability,
}:

let
  name = scope.instanceName;

  containerName = "${name}-reloader";

  # Selector labels match the Helm chart convention (app + release).
  reloaderSelectorLabels = {
    app = "${name}-reloader";
    release = name;
  };

  # Extra metadata labels from the Helm chart.
  reloaderExtraLabels = {
    group = "com.stakater.platform";
    provider = "stakater";
    version = "v1.3.0";
  };

  # --- RBAC DSL ---
  inherit (scope.rbac)
    core
    group
    grant
    watch
    allow
    emit
    mkClusterRoleSet
    ;
  apps = group "apps" [
    "deployments"
    "daemonsets"
    "statefulsets"
  ];
  batch = group "batch" [
    "cronjobs"
    "jobs"
  ];

in
{
  meta = {
    version = "v1.3.0";
    description = "Stakater Reloader, which restarts annotated workloads when a ConfigMap or Secret they reference changes";
    owner = "platform";
    # Reloader coordinates replicas only in its HA mode, which this package
    # does not enable, so one replica is the ceiling it can honour.
    availability.max = "pod";
  };

  options = {
    image = kix.options.image {
      repository = "ghcr.io/stakater/reloader";
      tag = "v1.3.0";
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # Fixed at 1: without reloader's HA mode a second replica would issue
      # every rolling restart twice. See meta.availability.max.
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

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      # --- RBAC ---
      clusterRoles = mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];
        roles = {
          "${name}-reloader-role" = {
            bindingName = "${name}-reloader-role-binding";
            rules = grant [
              (
                [
                  core.secrets
                  core.configmaps
                ]
                |> watch
              )
              (
                [
                  apps.deployments
                  apps.daemonsets
                  apps.statefulsets
                ]
                |> allow [
                  "list"
                  "get"
                  "update"
                  "patch"
                ]
              )
              (
                batch.cronjobs
                |> allow [
                  "list"
                  "get"
                ]
              )
              (
                batch.jobs
                |> allow [
                  "create"
                  "delete"
                  "list"
                  "get"
                ]
              )
              (core.events |> emit)
            ];
          };
        };
      };

    in
    {

      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-reloader";
      };

      # --- Deployment ---
      deployment =
        {
          name = "${name}-reloader";
          labels = reloaderExtraLabels;
          spec = {
            replicas = config.replicaCount;
            revisionHistoryLimit = 2;
            selector.matchLabels = reloaderSelectorLabels;
            template.metadata.labels = reloaderSelectorLabels // reloaderExtraLabels;
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              # Kubernetes' default, set explicitly; the chart sets none.
              terminationGracePeriodSeconds = 30;
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65534;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                {
                  name = containerName;
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  args =
                    lib.optional (config.logFormat != "") "--log-format=${config.logFormat}"
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
                    (kix.port "http" 9090)
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
                  # The chart's `reloader.readOnlyRootFileSystem` (reloader
                  # chart 2.0.0) sets this and mounts an emptyDir at /tmp.
                  securityContext.readOnlyRootFilesystem = true;
                }
              ];
            }
            // lib.optionalAttrs (config.priorityClassName != null) {
              priorityClassName = config.priorityClassName;
            };
          };
        }
        |> kix.withMounts [
          (kix.mount.emptyDir {
            name = "tmp-volume";
            mountPath = "/tmp/";
          })
        ]
        |> scope.mkDeployment;

      # --- Service (optional, metrics) ---
      service =
        if config.service.enabled then
          self.deployment |> kix.service.fromWorkload { name = "${name}-reloader"; } |> scope.mkResource
        else
          null;

      # --- Entry point ---
      root = self.deployment;
    }
    // clusterRoles;
}
