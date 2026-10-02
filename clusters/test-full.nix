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
          # Created outside Kix, as an existing Secret would be.
          valkey-auth = {
            package = packages.secret-ref;
            aliases = [ "valkeyPassword" ];
            config.keys = [ "password" ];
          };

          valkey = {
            package = packages.valkey;

            config = {
              replicas = 3;
              sentinel = {
                enabled = true;
                quorum = 2;
                primarySettings = {
                  down-after-milliseconds = 60000;
                  failover-timeout = 180000;
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
              settings = {
                maxmemory-policy = "allkeys-lru";
                save = [ "900 1" ];
              };
              metrics.resources = {
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
