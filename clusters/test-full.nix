# clusters/test-full.nix — Full cluster: all charts with most features enabled.
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
        # velero with no credentials at all: no Secret and no secret-ref
        # marker. clusters/test-operators.nix builds the managed-Secret path.
        velero.velero.package = packages.velero;
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
