# clusters/example.nix — Example cluster: coredns + valkey + cert-manager.
#
# Namespace-scoped instances with DI resolution.
#
# Build:  nix build .#cluster-example

{ kix, packages }:

kix.buildCluster {
  name = "example";
  modules = [
    {
      clusterLabels = {
        "app.kubernetes.io/part-of" = "kix-example";
        "team" = "platform";
      };

      namespaces = {
        kube-system = { };
        cert-manager = { };
        stackgres-system = { };
        immich = { };
      };

      instances = {
        kube-system = {
          # region:storageClassesInstance
          # rancher.io/local-path exists only where local-path-provisioner is
          # installed; name your cluster's CSI driver here.
          storage-classes = {
            package = packages.storage-classes;
            config.classes.local-path = {
              provisioner = "rancher.io/local-path";
              volumeBindingMode = "WaitForFirstConsumer";
            };
          };
          # endregion:storageClassesInstance

          coredns = {
            package = packages.coredns;

            config = {
              replicas = 2;
              clusterIP = "10.96.0.10";
            };
          };
        };

        cert-manager = {
          cert-manager = {
            package = packages.cert-manager;

          };
        };

        stackgres-system = {
          stackgres-operator = {
            package = packages.stackgres-operator;
          };
        };

        immich = {
          postgres = {
            package = packages."stackgres-cluster";

            config = {
              extensions = [
                {
                  name = "vector";
                  publisher = "tensorchord";
                  version = "0.3.0";
                }
              ];
            };
          };

          # Per-app database + role on the postgres cluster above.
          # Resolved via the `database` alias by the immich package.
          immich-db = {
            package = packages."stackgres-database";
            aliases = [ "database" ];
            config = {
              database = "immich";
              user = "immich";
              extensions = [ "vector" ];
              password = "immich-dev-password";
            };
          };

          storage = {
            package = packages."persistent-volume-claim";
            config = {
              size = "500Gi";
            };
          };

          # immich reads the password through a secretKeyRef, so valkey and
          # its password live in immich's namespace.
          valkey-password = {
            package = packages.secret;
            aliases = [ "valkeyPassword" ];
            config.stringData.password = "valkey-dev-password";
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

          immich = {
            package = packages.immich;
          };

          machine-learning = {
            package = packages."immich-machine-learning";
          };
        };
      };
    }
  ];
}
