# StackGres pgpass permissions workaround.
#
# Upstream issue: https://gitlab.com/ongresinc/stackgres/-/issues/1441
# Patroni reverts /var/lib/postgresql/pgpass to mode 0644 → replication
# breaks because libpq refuses world-readable .pgpass files.  This CronJob
# runs every 5 minutes, exec's into every Running StackGres pod, and
# chmod's the file back to 0600.  Drop this package once the operator
# upstream fixes the issue (versions.yml notes wal-g 3.0.3 + a future
# StackGres release should resolve it).
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding, CronJob.

{
  scope,
  lib,
}:

let
  saName = "stackgres-pgpass-perms-fix";
  labels = {
    app = saName;
    "app.kubernetes.io/component" = "stackgres-workaround";
  };
in
{
  meta = {
    version = "1.0.0";
    description = "CronJob workaround for StackGres #1441 (pgpass perms revert)";
    owner = "platform";
  };

  options = {
    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*/5 * * * *";
      description = "Cron schedule for the perms-fix Job.";
    };
    image = lib.mkOption {
      type = lib.types.str;
      default = "alpine/k8s:1.33.1";
    };
  };

  build =
    { self, config, ... }:
    {
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = saName;
        inherit labels;
      };

      # pods/exec is a powerful permission (equivalent to shell on every pod
      # cluster-wide).  Kubernetes RBAC cannot scope it by label, so the
      # broad grant is the cost of running this in-cluster.  Mitigate by
      # treating this ServiceAccount as a high-trust principal.
      clusterRole = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = saName;
        inherit labels;
        extra.rules = [
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
            resources = [ "pods/exec" ];
            verbs = [ "create" ];
          }
        ];
      };

      clusterRoleBinding = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = saName;
        inherit labels;
        extra = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "ClusterRole";
            name = self.clusterRole.out.name;
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.serviceAccount.out.name;
              namespace = scope.namespaceName;
            }
          ];
        };
      };

      cronJob = scope.mkCronJob {
        name = saName;
        inherit labels;
        spec = {
          schedule = config.schedule;
          concurrencyPolicy = "Forbid";
          successfulJobsHistoryLimit = 1;
          failedJobsHistoryLimit = 3;
          jobTemplate.spec = {
            backoffLimit = 0;
            template.metadata.labels = labels;
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              restartPolicy = "Never";
              containers = [
                {
                  name = "chmod-pgpass";
                  image = config.image;
                  imagePullPolicy = "Always";
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    runAsUser = 999;
                  };
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
                  command = [
                    "/bin/sh"
                    "-c"
                    ''
                      set -eu
                      kubectl get pods -A -l app=StackGresCluster \
                        --field-selector=status.phase=Running \
                        -o 'jsonpath={range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
                      | while read -r ns pod; do
                          [ -z "''${ns:-}" ] && continue
                          if ! kubectl -n "$ns" exec "$pod" -c patroni -- chmod 0600 /var/lib/postgresql/pgpass 2>&1; then
                            echo "WARN: chmod failed on $ns/$pod"
                          fi
                        done
                    ''
                  ];
                }
              ];
            };
          };
        };
      };

      # The ClusterRoleBinding and its ClusterRole are inverse dependencies:
      # the binding names the ServiceAccount that the CronJob uses.
      root = self.cronJob;
    };
}
