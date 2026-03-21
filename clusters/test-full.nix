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
      };

      instances = {
        kube-system = {
          coredns = {
            package = packages.coredns;
            packageType = "coredns";
            config = {
              replicaCount = 3;
              serviceAccount.create = true;
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
              podDisruptionBudget = {
                minAvailable = 1;
                maxUnavailable = null;
              };
              hpa = {
                enabled = true;
                minReplicas = 2;
                maxReplicas = 10;
                metrics = [
                  {
                    type = "Resource";
                    resource = {
                      name = "cpu";
                      target = {
                        type = "Utilization";
                        averageUtilization = 80;
                      };
                    };
                  }
                ];
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
              replicaCount = 3;
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
  ];
}
