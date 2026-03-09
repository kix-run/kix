# clusters/test-full.nix — Full cluster: all 3 charts with most features enabled.
#
# Stress test for cross-chart composition, monitoring, and registry.
# Every feature that can be enabled without external dependencies is enabled.

{
  cluster.labels = {
    "app.kubernetes.io/part-of" = "kix-full-test";
    "team" = "platform";
  };

  services.coredns = {
    enable = true;
    namespace = "kube-system";
    replicaCount = 3;
    serviceAccount.create = true;
    prometheus.service.enabled = true;
    prometheus.monitor.enabled = true;
    podDisruptionBudget.minAvailable = 1;
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

  services.valkey = {
    enable = true;
    namespace = "cache";
    sentinel.enabled = true;
    metrics.enabled = true;
    metrics.serviceMonitor.enabled = true;
    pdb.enabled = true;
    networkPolicy.enabled = true;
    auth.existingSecret = "valkey-auth";
    replica.autoscaling.hpa = {
      enabled = true;
      minReplicas = 2;
      maxReplicas = 8;
      targetCPU = 80;
    };
  };

  services.cert-manager = {
    enable = true;
    namespace = "cert-manager";
  };

  monitoring = {
    enabled = true;
    defaultInterval = "15s";
  };
}
