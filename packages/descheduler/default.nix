# Descheduler — evicts pods to rebalance cluster utilization.
#
# Wraps the upstream Kubernetes Descheduler Helm chart via fromHelmChart.
# Runs as a Deployment with periodic descheduling.
#
# Chart:   https://kubernetes-sigs.github.io/descheduler
# Name:    descheduler
# Version: 0.32.2
#
# Usage in cluster definition:
#
#   descheduler = {
#     package = kix.fromHelmChart {
#       chart = kix.fetchHelmChart {
#         repo = "https://kubernetes-sigs.github.io/descheduler";
#         name = "descheduler";
#         version = "0.32.2";
#         hash = "sha256-FIXME";
#       };
#       values = (import ./packages/descheduler).defaultValues;
#       releaseName = "descheduler";
#     };
#
#     config.values = { /* cluster-level overrides */ };
#   };

{
  chart = {
    repo = "https://kubernetes-sigs.github.io/descheduler";
    name = "descheduler";
    version = "0.32.2";
  };

  defaultValues = {
    # Deployment mode (not CronJob) — matches live cluster.
    kind = "Deployment";
    replicas = 0;

    deschedulingInterval = "5m";

    cmdOptions = {
      v = 3;
    };

    resources = {
      requests = {
        cpu = "10m";
        memory = "256Mi";
      };
      limits = {
        cpu = "500m";
        memory = "512Mi";
      };
    };

    priorityClassName = "system-cluster-critical";

    deschedulerPolicyAPIVersion = "descheduler/v1alpha2";

    deschedulerPolicy = {
      profiles = [
        {
          name = "default";
          pluginConfig = [
            {
              name = "DefaultEvictor";
              args = {
                evictLocalStoragePods = true;
                ignorePvcPods = true;
              };
            }
            { name = "RemoveDuplicates"; }
            {
              name = "RemovePodsHavingTooManyRestarts";
              args = {
                includingInitContainers = true;
                podRestartThreshold = 100;
              };
            }
            {
              name = "RemovePodsViolatingNodeAffinity";
              args = {
                nodeAffinityType = [
                  "requiredDuringSchedulingIgnoredDuringExecution"
                ];
              };
            }
            { name = "RemovePodsViolatingNodeTaints"; }
            { name = "RemovePodsViolatingInterPodAntiAffinity"; }
            { name = "RemovePodsViolatingTopologySpreadConstraint"; }
            {
              name = "LowNodeUtilization";
              args = {
                targetThresholds = {
                  cpu = 50;
                  memory = 50;
                  pods = 50;
                };
                thresholds = {
                  cpu = 20;
                  memory = 20;
                  pods = 20;
                };
              };
            }
          ];
          plugins = {
            balance = {
              enabled = [
                "RemoveDuplicates"
                "RemovePodsViolatingTopologySpreadConstraint"
                "LowNodeUtilization"
              ];
            };
            deschedule = {
              enabled = [
                "RemovePodsHavingTooManyRestarts"
                "RemovePodsViolatingNodeTaints"
                "RemovePodsViolatingNodeAffinity"
                "RemovePodsViolatingInterPodAntiAffinity"
              ];
            };
          };
        }
      ];
    };
  };
}
