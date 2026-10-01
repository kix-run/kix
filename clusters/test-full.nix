# clusters/test-full.nix: a full cluster, all charts with most features enabled.
#
# Stress test for package configs and optional resource gating.

{ kix, packages }:

kix.buildCluster {
  name = "test-full";
  modules = [
    {
      clusterLabels = {
        "app.kubernetes.io/part-of" = "kix-full-test";
        "team" = "platform";
      };

      namespaces = {
        kube-system = { };
        cache = { };
        cert-manager = { };
        velero = { };
      };

      instances = {
        # velero with every optional part on: the CSI data mover, a snapshot
        # location, a schedule, global volume policies, and maintenance
        # settings. Both secrets are secret-refs, created outside Kix.
        velero = {
          velero-credentials = {
            package = packages.secret-ref;
            aliases = [ "cloudCredentials" ];
            config.keys = [ "cloud" ];
          };
          velero-repo-credentials = {
            package = packages.secret-ref;
            aliases = [ "repositoryPassword" ];
            config.keys = [ "repository-password" ];
          };
          velero = {
            package = packages.velero;
            config = {
              features = [ "EnableCSI" ];
              backupStorageLocation = {
                objectStorage.bucket = "full-test";
                config.region = "us-east-1";
              };
              volumeSnapshotLocation.config.region = "us-east-1";
              schedules.nightly = {
                schedule = "CRON_TZ=UTC 0 3 * * *";
                template = {
                  ttl = "720h0m0s";
                  snapshotMoveData = true;
                };
              };
              volumePolicies = [
                {
                  conditions.csi = { };
                  action.type = "snapshot";
                }
                {
                  conditions.volumeTypes = [
                    "emptyDir"
                    "hostPath"
                  ];
                  action.type = "skip";
                }
              ];
              repositoryMaintenance.settings.keepLatestMaintenanceJobs = 3;
            };
          };
        };
        kube-system = {
          coredns = {
            package = packages.coredns;

            config = {
              replicas = 3;
              clusterIP = "10.96.0.10";
            };
          };
        };

        cache = {
          valkey = {
            package = packages.valkey;

            config = {
              sentinel = {
                enabled = true;
                quorum = 2;
                primarySet = "myprimary";
                downAfterMilliseconds = 60000;
                failoverTimeout = 180000;
                parallelSyncs = 1;
                image = {
                  repository = "docker.io/bitnami/valkey-sentinel";
                  tag = "8.1.1-debian-12-r0";
                  pullPolicy = "IfNotPresent";
                };
                resources = {
                  requests = {
                    cpu = "100m";
                    memory = "128Mi";
                    ephemeral-storage = "50Mi";
                  };
                  limits = {
                    cpu = "150m";
                    memory = "192Mi";
                    ephemeral-storage = "2Gi";
                  };
                };
              };
              metrics = {
                enabled = true;
                image = {
                  repository = "docker.io/bitnami/redis-exporter";
                  tag = "1.70.0-debian-12-r2";
                  pullPolicy = "IfNotPresent";
                };
                resources = {
                  requests = {
                    cpu = "100m";
                    memory = "128Mi";
                    ephemeral-storage = "50Mi";
                  };
                  limits = {
                    cpu = "150m";
                    memory = "192Mi";
                    ephemeral-storage = "2Gi";
                  };
                };
              };
              auth = {
                enabled = true;
                existingSecret = "valkey-auth";
                existingSecretPasswordKey = "valkey-password";
                sentinel = true;
              };
              replicaCount = 3;
            };
          };
        };

        cert-manager = {
          cert-manager = {
            package = packages.cert-manager;

          };
        };
      };
    }
  ];
}
