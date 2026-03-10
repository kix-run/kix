# CoreDNS resource construction and config wiring.
#
# This is the high-level composition pipeline. Domain-specific logic lives in:
#   helpers.nix    — Corefile builder, port derivation, labels, monitoring guards
#   containers.nix — Container definitions with pipe composition
#   rbac.nix       — ServiceAccounts, ClusterRoles, ClusterRoleBindings
#
# Returns { manifestList, extraConfig } per the mkChartModule contract.
# Source Helm chart: coredns/coredns (v1.45.0, appVersion 1.13.1)

{
  lib,
  config,
  kixlib,
  kixlib',
  cfg,
  labels,
  ...
}:

let
  helpers = import ./helpers.nix {
    inherit
      lib
      config
      kixlib
      cfg
      labels
      ;
  };
  containers = import ./containers.nix {
    inherit lib kixlib cfg;
    inherit helpers;
  };
  rbac = import ./rbac.nix {
    inherit
      lib
      config
      kixlib
      cfg
      ;
    inherit helpers;
  };

  inherit (helpers)
    hasPrometheus
    buildCorefile
    ports
    selectorLabels
    kixlibCoredns
    corednsFqdn
    monitoringGuard
    monitoringLabels
    monitoringAnnotations
    pdbEnabled
    ;

  inherit (kixlibCoredns.combinators)
    mkServiceDeployment
    optionalPipe
    withAutoscaler
    withPodDisruptionBudget
    withMetrics
    groupToManifestList
    ;

  # --- ConfigMap ---

  coreDnsConfigMap =
    kixlibCoredns.configMap.mkConfigMap { }
    |> kixlibCoredns.configMap.withEntry "Corefile" buildCorefile;

  configVolume =
    coreDnsConfigMap
    |> kixlibCoredns.configMap.asVolume {
      name = "config-volume";
      items = [
        {
          key = "Corefile";
          path = "Corefile";
        }
      ]
      ++ map (zf: {
        key = zf.filename;
        path = zf.filename;
      }) cfg.zoneFiles;
    };

  # --- Main pipeline: Deployment + Service + optional metrics/HPA/PDB ---

  mainGroup =
    mkServiceDeployment {
      name = "coredns";
      containers = [ containers.coredns ];
      inherit selectorLabels;
      servicePorts = ports.servicePorts;
      replicas = if cfg.hpa.enabled || cfg.autoscaler.enabled then null else cfg.replicaCount;
      serviceType = cfg.serviceType;
      strategy = {
        type = "RollingUpdate";
        rollingUpdate = {
          maxUnavailable = 1;
          maxSurge = "25%";
        };
      };
      volumes = [ configVolume ];
      serviceAccountName = rbac.serviceAccountName;
      deploymentLabels = {
        "app.kubernetes.io/version" = cfg.image.tag;
      };
      podAnnotations = lib.optionalAttrs cfg.isClusterService {
        "scheduler.alpha.kubernetes.io/tolerations" =
          ''[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'';
      };
      podSpec = {
        terminationGracePeriodSeconds = 30;
      }
      // lib.optionalAttrs cfg.isClusterService { dnsPolicy = "Default"; };
    }
    |> optionalPipe (hasPrometheus && cfg.prometheus.service.enabled) (withMetrics {
      workloadKey = "coredns-deployment";
      metricsName = "coredns-service-metrics";
      metricsServiceName = "coredns-metrics";
      metricsPort = 9153;
      monitoringLabels = monitoringLabels;
      monitoringAnnotations = monitoringAnnotations;
      extraServiceAnnotations = cfg.prometheus.service.annotations;
    })
    |> optionalPipe cfg.hpa.enabled (withAutoscaler {
      workloadKey = "coredns-deployment";
      hpaName = "coredns-hpa";
      hpaArgs = { inherit (cfg.hpa) minReplicas maxReplicas metrics; };
    })
    |> optionalPipe pdbEnabled (withPodDisruptionBudget {
      workloadKey = "coredns-deployment";
      pdbName = "coredns-poddisruptionbudget";
      pdbArgs =
        { }
        // lib.optionalAttrs (cfg.podDisruptionBudget.minAvailable != null) {
          minAvailable = cfg.podDisruptionBudget.minAvailable;
        }
        // lib.optionalAttrs (cfg.podDisruptionBudget.maxUnavailable != null) {
          maxUnavailable = cfg.podDisruptionBudget.maxUnavailable;
        };
    });

  # --- Autoscaler sub-deployment (separate kixlib, cannot pipe into main group) ---

  autoscalerConfigObj = {
    inherit (cfg.autoscaler)
      coresPerReplica
      nodesPerReplica
      preventSinglePointFailure
      min
      max
      includeUnschedulableNodes
      ;
  };
  autoscalerConfigData = builtins.toJSON autoscalerConfigObj;

  autoscalerConfigMap =
    rbac.autoscalerKixlib.configMap.mkConfigMap { }
    |> rbac.autoscalerKixlib.configMap.withEntry "linear" autoscalerConfigData;

  autoscalerDeployment = rbac.autoscalerKixlib.workload.mkDeployment {
    replicas = null;
    selectorLabels = rbac.autoscalerSelectorLabels;
    template = rbac.autoscalerKixlib.pod.mkPodTemplate {
      metadata = {
        labels = rbac.autoscalerSelectorLabels;
        annotations = {
          "checksum/configmap" = builtins.hashString "sha256" autoscalerConfigData;
        }
        // lib.optionalAttrs cfg.isClusterService {
          "scheduler.alpha.kubernetes.io/tolerations" =
            ''[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'';
        };
      };
      spec = {
        containers = [ (containers.autoscaler rbac.autoscalerKixlib) ];
        serviceAccountName = rbac.autoscalerName;
      };
    };
  };

in
{
  manifestList =
    groupToManifestList mainGroup
    ++ [
      {
        name = "coredns-configmap";
        resource = coreDnsConfigMap;
        enable = true;
      }
    ]
    ++ rbac.manifestList
    ++ rbac.autoscalerManifestList
    ++ [
      {
        name = "coredns-autoscaler-configmap";
        resource = autoscalerConfigMap;
        enable = cfg.autoscaler.enabled;
        kixlib = rbac.autoscalerKixlib;
      }
      {
        name = "coredns-autoscaler-deployment";
        resource = autoscalerDeployment;
        enable = cfg.autoscaler.enabled;
        kixlib = rbac.autoscalerKixlib;
      }
    ];

  extraConfig = {
    # Level 2: service registry
    registry.coredns = {
      endpoints = {
        dns-udp = {
          host = corednsFqdn;
          port = 53;
          protocol = "dns-udp";
        };
        dns-tcp = {
          host = corednsFqdn;
          port = 53;
          protocol = "dns-tcp";
        };
      }
      // lib.optionalAttrs hasPrometheus {
        metrics = {
          host = corednsFqdn;
          port = 9153;
          protocol = "http";
        };
      };
    };

    # V4 capability: monitoring target.
    # Guard MUST match monitoringGuard in helpers.nix (doc 12 rule #10).
    capabilities.monitoring.coredns = lib.mkIf monitoringGuard {
      serviceName = "coredns-metrics";
      namespace = cfg.namespace;
      portName = "metrics";
      port = 9153;
      path = "/metrics";
      selector = selectorLabels // {
        "app.kubernetes.io/component" = "metrics";
      };
    };

    # Level 3: network policy declaration
    networkPolicies.services.coredns = {
      namespace = cfg.namespace;
      podSelector = selectorLabels;
      ingressPorts = [ 53 ];
      egressTo = [ ];
    };
  };
}
