# clusters/example.nix — Example cluster: coredns + valkey + cert-manager.
#
# Namespace-scoped instances with DI resolution.
#
# Build:  nix build .#cluster-example

{ kix, packages }:

kix.buildCluster {
  name = "example";
  clusterLabels = {
    "app.kubernetes.io/part-of" = "kix-example";
    "team" = "platform";
  };

  namespaces = {
    kube-system = { };
    cache = { };
    cert-manager = { };
  };

  instances =
    { ref, ... }:
    {
      kube-system = {
        coredns = {
          package = packages.coredns;
          packageType = "coredns";
          config = {
            replicaCount = 2;
            prometheus = {
              service = {
                enabled = true;
                annotations = {
                  "prometheus.io/scrape" = "true";
                  "prometheus.io/port" = "9153";
                };
              };
              monitor = {
                enabled = true;
                interval = null;
              };
            };
          };
        };
      };

      cache = {
        valkey = {
          package = packages.valkey;
          packageType = "valkey";
          config = {
            sentinel = {
              enabled = true;
              quorum = 2;
              primarySet = "myprimary";
              downAfterMilliseconds = 60000;
              failoverTimeout = 180000;
              parallelSyncs = 1;
              configuration = "";
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
          };
        };
      };

      cert-manager = {
        cert-manager = {
          package = packages.cert-manager;
          packageType = "cert-manager";
        };
      };
    };
}
