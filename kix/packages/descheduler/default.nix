# Descheduler — evicts pods to rebalance cluster utilization.
#
# Wraps the upstream Kubernetes Descheduler Helm chart.
# Runs as a Deployment with periodic descheduling.
#
# Chart:   https://kubernetes-sigs.github.io/descheduler
# Name:    descheduler
# Version: 0.32.2

{ scope, lib }:
let
  chart = scope.helm.fetchHelmChart {
    repo = "https://kubernetes-sigs.github.io/descheduler";
    name = "descheduler";
    version = "0.32.2";
    hash = "sha256-ARIFySRZdUP+k79s5m11ozvGp9GgKe7dTAOQoW5X4mQ=";
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
in
{
  meta.version = "0.32.2";

  options.values = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Helm values to deep-merge with the chart's package-level values.";
  };

  build =
    { config, scope, ... }:
    let
      resources = scope.helm.importChart {
        inherit chart scope;
        values = lib.recursiveUpdate defaultValues (config.values or { });
        releaseName = "descheduler";
      };
    in
    resources.mkParts {
      root = resources.get "Deployment" "descheduler";
    };
}
