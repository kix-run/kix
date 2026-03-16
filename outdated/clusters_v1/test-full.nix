# clusters/test-full.nix — Full cluster: all 3 charts with most features enabled.
#
# Stress test for package overrides and optional resource gating.
# Every feature that can be enabled without external dependencies is enabled.

{ k8s, lib }:

let
  clusterLabels = {
    "app.kubernetes.io/part-of" = "kix-full-test";
    "team" = "platform";
  };
in

k8s.mkCluster {
  basePackages = self: {
    coredns = (import ../pkgs-fp/coredns { inherit k8s lib; }).override {
      namespace = "kube-system";
      replicaCount = 3;
      serviceAccount = {
        create = true;
      };
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
      inherit clusterLabels;
    };

    valkey = (import ../pkgs-fp/valkey { inherit k8s lib; }).override {
      namespace = "cache";
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
      pdb = {
        enabled = true;
        maxUnavailable = 1;
        minAvailable = null;
      };
      networkPolicy = {
        enabled = true;
      };
      auth = {
        enabled = true;
        existingSecret = "valkey-auth";
        existingSecretPasswordKey = "valkey-password";
        sentinel = true;
      };
      replica = {
        replicaCount = 3;
        configuration = "";
        disableCommands = [
          "FLUSHDB"
          "FLUSHALL"
        ];
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
        autoscaling = {
          hpa = {
            enabled = true;
            minReplicas = 2;
            maxReplicas = 8;
            targetCPU = 80;
            targetMemory = null;
          };
        };
      };
      inherit clusterLabels;
    };

    cert-manager = (import ../pkgs-fp/cert-manager { inherit k8s lib; }).override {
      namespace = "cert-manager";
      inherit clusterLabels;
    };
  };
}
