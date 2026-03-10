# Valkey resource construction and config wiring.
#
# This is the high-level composition pipeline. Domain-specific logic lives in:
#   helpers.nix    — Naming, labels, volumes, env vars, pod spec, monitoring guards
#   containers.nix — Container definitions (primary, replica, sentinel, metrics)
#   configmaps.nix — Configuration, health scripts, start scripts
#
# Returns { manifestList, extraConfig } per the mkChartModule contract.
# Source Helm chart: oci://registry-1.docker.io/bitnamicharts/valkey (v3.0.2)
#
# Two modes:
#   REPLICATION (default): primary SS + replica SS + separate services/SAs
#   SENTINEL (sentinel.enabled = true): single "node" SS with valkey + sentinel + metrics containers

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
      ;
  };
  containers = import ./containers.nix {
    inherit lib kixlib cfg;
    inherit helpers;
  };
  configmaps = import ./configmaps.nix {
    inherit cfg;
    inherit helpers;
  };

  inherit (helpers)
    fullname
    headlessSvcName
    headlessSvcFqdn
    fqdn
    totalReplicas
    labels
    kixlib'
    passwordVolume
    startScriptsVolume
    healthVolume
    configVolume
    emptyDirVolume
    mkDataVolumeClaimTemplate
    mkPodSpec
    monitoringGuard
    valkeyMonitoringLabels
    valkeyMonitoringAnnotations
    ;

  inherit (kixlib'.combinators)
    optionalPipe
    withMetrics
    groupToManifestList
    withEnable
    ;

  # ============================================================
  # SERVICE ACCOUNTS
  # ============================================================

  # Sentinel mode: single shared SA named "valkey"
  # Replication mode: separate SAs per component
  sa = kixlib'.rbac.mkServiceAccount {
    metadata.name = fullname;
    automountServiceAccountToken = false;
  };

  primarySa = kixlib'.rbac.mkServiceAccount {
    metadata.name = "${fullname}-primary";
    automountServiceAccountToken = false;
  };

  replicaSa = kixlib'.rbac.mkServiceAccount {
    metadata.name = "${fullname}-replica";
    automountServiceAccountToken = false;
  };

  # ============================================================
  # HEADLESS SERVICE (shared across both modes)
  # ============================================================

  headlessSvc = kixlib'.networking.mkService {
    metadata.name = headlessSvcName;
    spec = {
      type = "ClusterIP";
      clusterIP = "None";
      ports = [
        {
          name = "tcp-redis";
          port = 6379;
          targetPort = "redis";
        }
      ]
      ++ lib.optionals cfg.sentinel.enabled [
        {
          name = "tcp-sentinel";
          port = 26379;
          targetPort = "valkey-sentinel";
        }
      ];
      selector = labels.selector;
    }
    // lib.optionalAttrs cfg.sentinel.enabled {
      publishNotReadyAddresses = true;
    };
  };

  # ============================================================
  # SENTINEL MODE RESOURCES
  # ============================================================

  sentinelSvc = kixlib'.networking.mkService {
    metadata = {
      name = fullname;
      labels = labels.all // {
        "app.kubernetes.io/component" = "node";
      };
    };
    spec = {
      type = "ClusterIP";
      sessionAffinity = "None";
      ports = [
        {
          name = "tcp-redis";
          port = 6379;
          targetPort = 6379;
        }
        {
          name = "tcp-sentinel";
          port = 26379;
          targetPort = 26379;
        }
      ];
      selector = labels.withComponent "node";
    };
  };

  sentinelStatefulSet = kixlib'.workload.mkStatefulSet {
    metadata = {
      name = "${fullname}-node";
      labels = labels.all // {
        "app.kubernetes.io/component" = "node";
      };
    };
    replicas = totalReplicas;
    serviceName = headlessSvcName;
    selectorLabels = labels.withComponent "node";
    updateStrategy = {
      type = "RollingUpdate";
    };
    template = kixlib'.pod.mkPodTemplate {
      metadata = {
        labels = labels.withComponent "node";
        annotations = lib.optionalAttrs cfg.metrics.enabled {
          "prometheus.io/port" = "9121";
          "prometheus.io/scrape" = "true";
        };
      };
      spec = mkPodSpec {
        serviceAccountName = fullname;
        componentLabels = labels.withComponent "node";
        containers = [
          containers.sentinelValkey
          containers.sentinel
        ]
        ++ lib.optionals cfg.metrics.enabled [ containers.metrics ];
        volumes = [
          startScriptsVolume
          healthVolume
          passwordVolume
          configVolume
          {
            name = "sentinel-data";
            emptyDir = { };
          }
          emptyDirVolume
        ];
      };
    };
    volumeClaimTemplates = mkDataVolumeClaimTemplate (labels.withComponent "node");
  };

  # ============================================================
  # REPLICATION MODE RESOURCES
  # ============================================================

  primaryStatefulSet = kixlib'.workload.mkStatefulSet {
    metadata = {
      name = "${fullname}-primary";
      labels = labels.all // {
        "app.kubernetes.io/component" = "primary";
      };
    };
    replicas = 1;
    serviceName = headlessSvcName;
    selectorLabels = labels.withComponent "primary";
    updateStrategy = {
      type = "RollingUpdate";
    };
    template = kixlib'.pod.mkPodTemplate {
      metadata.labels = labels.withComponent "primary";
      spec = mkPodSpec {
        serviceAccountName = "${fullname}-primary";
        componentLabels = labels.withComponent "primary";
        containers = [ containers.primary ];
        volumes = [
          startScriptsVolume
          healthVolume
          passwordVolume
          configVolume
          emptyDirVolume
        ];
      };
    };
    volumeClaimTemplates = mkDataVolumeClaimTemplate (labels.withComponent "primary");
  };

  primarySvc = kixlib'.networking.mkService {
    metadata = {
      name = "${fullname}-primary";
      labels = labels.all // {
        "app.kubernetes.io/component" = "primary";
      };
    };
    spec = {
      type = "ClusterIP";
      internalTrafficPolicy = "Cluster";
      sessionAffinity = "None";
      ports = [
        {
          name = "tcp-redis";
          port = 6379;
          targetPort = "redis";
        }
      ];
      selector = labels.withComponent "primary";
    };
  };

  replicaStatefulSet = kixlib'.workload.mkStatefulSet {
    metadata = {
      name = "${fullname}-replicas";
      labels = labels.all // {
        "app.kubernetes.io/component" = "replica";
      };
    };
    replicas = cfg.replica.replicaCount;
    serviceName = headlessSvcName;
    selectorLabels = labels.withComponent "replica";
    updateStrategy = {
      type = "RollingUpdate";
    };
    template = kixlib'.pod.mkPodTemplate {
      metadata.labels = labels.withComponent "replica";
      spec = mkPodSpec {
        serviceAccountName = "${fullname}-replica";
        componentLabels = labels.withComponent "replica";
        containers = [ containers.replica ];
        volumes = [
          startScriptsVolume
          healthVolume
          passwordVolume
          configVolume
          emptyDirVolume
        ];
      };
    };
    volumeClaimTemplates = mkDataVolumeClaimTemplate (labels.withComponent "replica");
  };

  replicaSvc = kixlib'.networking.mkService {
    metadata = {
      name = "${fullname}-replicas";
      labels = labels.all // {
        "app.kubernetes.io/component" = "replica";
      };
    };
    spec = {
      type = "ClusterIP";
      internalTrafficPolicy = "Cluster";
      sessionAffinity = "None";
      ports = [
        {
          name = "tcp-redis";
          port = 6379;
          targetPort = "redis";
        }
      ];
      selector = labels.withComponent "replica";
    };
  };

  # ============================================================
  # SHARED OPTIONAL RESOURCES (both modes)
  # ============================================================

  # --- Metrics Service via pipeline ---
  # Uses explicit `selector` (base labels, no component) to match ALL valkey pods.
  metricsGroup =
    { }
    |> optionalPipe cfg.metrics.enabled (withMetrics {
      selector = labels.selector;
      metricsName = "valkey-metrics";
      metricsServiceName = "${fullname}-metrics";
      metricsPort = 9121;
      portName = "http-metrics";
      monitoringLabels = valkeyMonitoringLabels;
      monitoringAnnotations = valkeyMonitoringAnnotations;
      extraLabels = labels.all;
    });

  # Network policy
  networkPolicy = kixlib'.networking.mkNetworkPolicy {
    metadata.name = fullname;
    podSelector.matchLabels = labels.selector;
    policyTypes = [
      "Ingress"
      "Egress"
    ];
    egress = [ { } ];
    ingress = [
      { ports = [ { port = 6379; } ] ++ lib.optionals cfg.sentinel.enabled [ { port = 26379; } ]; }
    ]
    ++ lib.optionals cfg.metrics.enabled [
      { ports = [ { port = 9121; } ]; }
    ];
  };

  # PodDisruptionBudgets (different per mode)
  sentinelPdb = kixlib'.policy.mkPodDisruptionBudget {
    metadata = {
      name = "${fullname}-node";
      labels = labels.all // {
        "app.kubernetes.io/component" = "node";
      };
    };
    selector.matchLabels = labels.withComponent "node";
    maxUnavailable = cfg.pdb.maxUnavailable;
    minAvailable = cfg.pdb.minAvailable;
  };

  replicaPdb = kixlib'.policy.mkPodDisruptionBudget {
    metadata = {
      name = "${fullname}-replicas";
      labels = labels.all // {
        "app.kubernetes.io/component" = "replica";
      };
    };
    selector.matchLabels = labels.withComponent "replica";
    maxUnavailable = cfg.pdb.maxUnavailable;
    minAvailable = cfg.pdb.minAvailable;
  };

  # HPA — targets replica SS in replication mode, node SS in sentinel mode.
  replicaHpa = kixlib'.autoscaling.mkHorizontalPodAutoscaler {
    metadata = {
      name = if cfg.sentinel.enabled then "${fullname}-node" else "${fullname}-replicas";
      labels = labels.all // {
        "app.kubernetes.io/component" = "replica";
      };
    };
    scaleTargetRef = {
      apiVersion = "apps/v1";
      kind = "StatefulSet";
      name = if cfg.sentinel.enabled then "${fullname}-node" else "${fullname}-replicas";
    };
    inherit (cfg.replica.autoscaling.hpa) minReplicas maxReplicas;
    metrics =
      lib.optional (cfg.replica.autoscaling.hpa.targetCPU != null) {
        type = "Resource";
        resource = {
          name = "cpu";
          target = {
            type = "Utilization";
            averageUtilization = cfg.replica.autoscaling.hpa.targetCPU;
          };
        };
      }
      ++ lib.optional (cfg.replica.autoscaling.hpa.targetMemory != null) {
        type = "Resource";
        resource = {
          name = "memory";
          target = {
            type = "Utilization";
            averageUtilization = cfg.replica.autoscaling.hpa.targetMemory;
          };
        };
      };
  };

  # Monitoring resources (PodMonitor, PrometheusRule, ServiceMonitor)
  podMonitor = kixlib'.monitoring.mkPodMonitor {
    metadata = {
      name = fullname;
      namespace = cfg.namespace;
      labels = labels.all;
    };
    podMetricsEndpoints = [
      {
        port = "metrics";
        interval = cfg.metrics.podMonitor.interval;
      }
    ];
    namespaceSelector.matchNames = [ cfg.namespace ];
    selector.matchLabels = labels.selector;
  };

  prometheusRule = kixlib'.monitoring.mkPrometheusRule {
    metadata = {
      name = fullname;
      namespace = cfg.namespace;
      labels = labels.all;
    };
    groups = [
      {
        name = fullname;
        rules = cfg.metrics.prometheusRule.rules;
      }
    ];
  };

  serviceMonitor = kixlib'.monitoring.mkServiceMonitor {
    metadata = {
      name = fullname;
    }
    // lib.optionalAttrs (cfg.metrics.serviceMonitor.namespace != null) {
      namespace = cfg.metrics.serviceMonitor.namespace;
    };
    endpoints = [
      {
        port = "http-metrics";
        interval = cfg.metrics.serviceMonitor.interval;
      }
    ];
    namespaceSelector.matchNames = [ cfg.namespace ];
    selector.matchLabels = labels.selector // {
      "app.kubernetes.io/component" = "metrics";
    };
  };

  # --- Declarative manifest list ---
  manifestList = [
    # Common to both modes
    {
      name = "valkey-configuration";
      resource = configmaps.configuration;
      enable = true;
    }
    {
      name = "valkey-health";
      resource = configmaps.health;
      enable = true;
    }
    {
      name = "valkey-scripts";
      resource = configmaps.scripts;
      enable = true;
    }
    {
      name = "valkey-headless";
      resource = headlessSvc;
      enable = true;
    }
    # Sentinel mode
    {
      name = "valkey-serviceaccount";
      resource = sa;
      enable = cfg.sentinel.enabled;
    }
    {
      name = "valkey-service";
      resource = sentinelSvc;
      enable = cfg.sentinel.enabled;
    }
    {
      name = "valkey-node";
      resource = sentinelStatefulSet;
      enable = cfg.sentinel.enabled;
    }
    # Replication mode
    {
      name = "valkey-primary-serviceaccount";
      resource = primarySa;
      enable = !cfg.sentinel.enabled;
    }
    {
      name = "valkey-replica-serviceaccount";
      resource = replicaSa;
      enable = !cfg.sentinel.enabled;
    }
    {
      name = "valkey-primary-service";
      resource = primarySvc;
      enable = !cfg.sentinel.enabled;
    }
    {
      name = "valkey-replica-service";
      resource = replicaSvc;
      enable = !cfg.sentinel.enabled;
    }
    {
      name = "valkey-primary";
      resource = primaryStatefulSet;
      enable = !cfg.sentinel.enabled;
    }
    {
      name = "valkey-replicas";
      resource = replicaStatefulSet;
      enable = !cfg.sentinel.enabled;
    }
    # Optional resources
    {
      name = "valkey-networkpolicy";
      resource = networkPolicy;
      enable = cfg.networkPolicy.enabled;
    }
    {
      name = "valkey-pdb";
      resource = sentinelPdb;
      enable = cfg.pdb.enabled && cfg.sentinel.enabled;
    }
    {
      name = "valkey-replica-pdb";
      resource = replicaPdb;
      enable = cfg.pdb.enabled && !cfg.sentinel.enabled;
    }
    {
      name = "valkey-podmonitor";
      resource = podMonitor;
      enable = cfg.metrics.enabled && cfg.metrics.podMonitor.enabled;
    }
    {
      name = "valkey-prometheusrule";
      resource = prometheusRule;
      enable = cfg.metrics.enabled && cfg.metrics.prometheusRule.enabled;
    }
    {
      name = "valkey-hpa";
      resource = replicaHpa;
      enable = cfg.replica.autoscaling.hpa.enabled;
    }
  ]
  ++ withEnable cfg.metrics.enabled (groupToManifestList metricsGroup);

in
{
  inherit manifestList;

  extraConfig = {
    # Level 2: service registry
    registry.valkey = {
      endpoints =
        (
          if cfg.sentinel.enabled then
            {
              primary = {
                host = fqdn fullname;
                port = 6379;
                protocol = "redis";
              };
            }
          else
            {
              primary = {
                host = fqdn "${fullname}-primary";
                port = 6379;
                protocol = "redis";
              };
              replicas = {
                host = fqdn "${fullname}-replicas";
                port = 6379;
                protocol = "redis";
              };
            }
        )
        // lib.optionalAttrs cfg.sentinel.enabled {
          sentinel = {
            host = fqdn fullname;
            port = 26379;
            protocol = "redis-sentinel";
          };
        }
        // lib.optionalAttrs cfg.metrics.enabled {
          metrics = {
            host = fqdn "${fullname}-metrics";
            port = 9121;
            protocol = "http";
          };
        };
    };

    # V4 capability: monitoring target.
    # Guard MUST match monitoringGuard in helpers.nix (doc 12 rule #10).
    capabilities.monitoring.valkey = lib.mkIf monitoringGuard {
      serviceName = "${fullname}-metrics";
      namespace = cfg.namespace;
      portName = "http-metrics";
      port = 9121;
      path = "/metrics";
      selector = labels.selector // {
        "app.kubernetes.io/component" = "metrics";
      };
    };

    # Level 3: network policy declaration
    networkPolicies.services.valkey = {
      namespace = cfg.namespace;
      podSelector = labels.selector;
      ingressPorts = [
        6379
      ]
      ++ lib.optionals cfg.sentinel.enabled [ 26379 ]
      ++ lib.optionals cfg.metrics.enabled [ 9121 ];
      egressTo = [ ];
    };
  };
}
