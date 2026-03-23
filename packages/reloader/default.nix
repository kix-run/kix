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
  kix,
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
  inherit (scope.rbac) core group grant watch allow emit mkClusterRoleSet;
  apps  = group "apps"  [ "deployments" "daemonsets" "statefulsets" ];
  batch = group "batch" [ "cronjobs" "jobs" ];

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
  let
    # --- RBAC ---
    clusterRoles = mkClusterRoleSet scope {
      subjects = [{ kind = "ServiceAccount"; name = self.serviceAccount.out.name; namespace = scope.namespaceName; }];
      roles = {
        "${name}-reloader-role" = {
          bindingName = "${name}-reloader-role-binding";
          rules = grant [
            ([core.secrets core.configmaps]                          |> watch)
            ([apps.deployments apps.daemonsets apps.statefulsets]     |> allow [ "list" "get" "update" "patch" ])
            (batch.cronjobs                                          |> allow [ "list" "get" ])
            (batch.jobs                                              |> allow [ "create" "delete" "list" "get" ])
            (core.events                                             |> emit)
          ];
        };
      };
    };

  in {

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
          template.metadata.labels = reloaderExtraLabels;
          template.spec = {
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
                securityContext = { };
              }
            ];
          } // lib.optionalAttrs (config.priorityClassName != null) {
            priorityClassName = config.priorityClassName;
          };
        };
      }
      |> scope.mkDeployment;

    # --- Service (optional, metrics) ---
    service =
      if config.service.enabled then
        self.deployment |> kix.service.fromWorkload { name = "${name}-reloader"; } |> scope.mkResource
      else
        null;

    # --- Entry point ---
    main = self.deployment;
  } // clusterRoles;
}
