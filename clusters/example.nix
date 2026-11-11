# clusters/example.nix: an example cluster with coredns, valkey, cert-manager, and immich.
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
            package = packages.experimental.coredns;

            config = {
              replicas = 2;
              clusterIP = "10.96.0.10";
            };
          };
        };

        cert-manager = {
          cert-manager = {
            package = packages.experimental.cert-manager;

          };
        };

        stackgres-system = {
          stackgres-operator = {
            package = packages.experimental.stackgres-operator;
          };
        };

        immich = {
          postgres = {
            package = packages.experimental."stackgres-cluster";
          };

          # Per-app database + role on the postgres cluster above, resolved
          # through the `database` alias. immich adds the extensions it needs
          # to this instance, which forwards them to the postgres cluster.
          immich-db = {
            package = packages.experimental."stackgres-database";
            aliases = [ "database" ];
            config = {
              database = "immich";
              user = "immich";
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
          # its password live in immich's namespace. The inline password is
          # for development only; outside it, use a SOPS `source` with
          # keys = [ "password" ], or a secret-ref.
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
            package = packages.experimental.immich;
          };

          machine-learning = {
            package = packages.experimental."immich-machine-learning";
          };

          # Keeps the downloaded models across restarts; the worker then runs
          # one pod.
          ml-cache = {
            package = packages."persistent-volume-claim";
            aliases = [ "modelCache" ];
            config.size = "10Gi";
          };
        };
      };
    }
  ];
}
