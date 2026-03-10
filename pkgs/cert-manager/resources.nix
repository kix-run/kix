# cert-manager resource construction and config wiring.
#
# This is the high-level composition pipeline. Domain-specific logic lives in:
#   helpers.nix    — Component labels, security contexts, monitoring guards, mkComponent
#   containers.nix — Container definitions with pipe composition
#   rbac.nix       — ServiceAccounts, ClusterRoles, RoleBindings (bulk of the code)
#   webhooks.nix   — MutatingWebhookConfiguration, ValidatingWebhookConfiguration
#
# Returns { manifestList, extraConfig } per the mkChartModule contract.
# Source Helm chart: jetstack/cert-manager (v1.19.4)
# Components: controller, webhook, cainjector, startupapicheck

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
      kixlib'
      cfg
      ;
  };
  containers = import ./containers.nix {
    inherit
      lib
      kixlib
      kixlib'
      cfg
      ;
    inherit helpers;
  };
  rbac = import ./rbac.nix {
    inherit
      lib
      kixlib
      kixlib'
      cfg
      ;
    inherit helpers;
  };
  webhooks = import ./webhooks.nix {
    inherit kixlib' cfg;
    inherit helpers;
  };

  inherit (helpers)
    controllerLabels
    webhookLabels
    cainjectorLabels
    startupapicheckLabels
    podSecurityContext
    containerSecCtx
    podNamespaceEnv
    nodeSelector
    controllerMonitoringLabels
    controllerMonitoringAnnotations
    webhookMonitoringLabels
    webhookMonitoringAnnotations
    cainjectorMonitoringLabels
    cainjectorMonitoringAnnotations
    mkComponent
    ;

  inherit (kixlib'.combinators) groupToManifestList withEnable;

  # ============================================================================
  # COMPONENT GROUPS (Deployment + Service per component)
  # ============================================================================

  controllerGroup = mkComponent {
    componentName = "cert-manager";
    componentLabels = controllerLabels // {
      selector = controllerLabels.selector // {
        "app.kubernetes.io/component" = "controller";
      };
      all = controllerLabels.all // {
        "app.kubernetes.io/component" = "controller";
      };
    };
    container = containers.controller;
    replicas = cfg.replicaCount;
    servicePorts = [
      {
        port = 9402;
        protocol = "TCP";
        targetPort = "http-metrics";
        name = "tcp-prometheus-servicemonitor";
      }
    ];
    serviceAccountName = "cert-manager";
    monitoringLabels = controllerMonitoringLabels;
    monitoringAnnotations = controllerMonitoringAnnotations;
  };

  webhookGroup = mkComponent {
    componentName = "cert-manager-webhook";
    componentLabels = webhookLabels;
    deploymentLabels = webhookLabels.all;
    container = containers.webhook;
    replicas = cfg.webhook.replicaCount;
    servicePorts = [
      {
        port = 443;
        protocol = "TCP";
        targetPort = "https";
        name = "https";
      }
      {
        port = 9402;
        protocol = "TCP";
        targetPort = "http-metrics";
        name = "metrics";
      }
    ];
    serviceAccountName = "cert-manager-webhook";
    monitoringLabels = webhookMonitoringLabels;
    monitoringAnnotations = webhookMonitoringAnnotations;
  };

  cainjectorGroup = mkComponent {
    componentName = "cert-manager-cainjector";
    componentLabels = cainjectorLabels;
    deploymentLabels = cainjectorLabels.all;
    container = containers.cainjector;
    replicas = cfg.cainjector.replicaCount;
    servicePorts = [
      {
        port = 9402;
        protocol = "TCP";
        name = "http-metrics";
      }
    ];
    serviceAccountName = "cert-manager-cainjector";
    monitoringLabels = cainjectorMonitoringLabels;
    monitoringAnnotations = cainjectorMonitoringAnnotations;
  };

  # ============================================================================
  # STARTUP API CHECK (Job, not a long-running component)
  # ============================================================================

  startupapicheckJob = kixlib'.workload.mkJob {
    metadata = {
      name = "cert-manager-startupapicheck";
      labels = startupapicheckLabels.all;
    };
    backoffLimit = 4;
    template = kixlib'.pod.mkPodTemplate {
      metadata = {
        labels = startupapicheckLabels.all;
      };
      spec = {
        restartPolicy = "OnFailure";
        containers = [ containers.startupapicheck ];
        serviceAccountName = "cert-manager-startupapicheck";
        enableServiceLinks = false;
        securityContext = podSecurityContext;
        inherit nodeSelector;
      };
    };
  };

in
{
  manifestList =
    # Controller: SA + Deployment + Service + cluster RBAC + aggregated roles + namespaced RBAC
    [
      {
        name = "cert-manager-sa";
        resource = rbac.controllerSa;
        enable = cfg.serviceAccount.create;
      }
    ]
    ++ groupToManifestList controllerGroup
    ++ rbac.controllerRbac.toManifestList cfg.rbac.create
    ++ lib.mapAttrsToList (n: role: {
      name = "cert-manager-clusterrole-${n}";
      resource = role;
      enable = cfg.rbac.create && cfg.rbac.aggregateClusterRoles;
    }) rbac.aggregatedClusterRoles
    ++ rbac.controllerNamespacedRbac.toManifestList cfg.rbac.create
    # Webhook: SA + Deployment + Service + admission webhooks + RBAC
    ++ [
      {
        name = "cert-manager-webhook-sa";
        resource = rbac.webhookSa;
        enable = cfg.serviceAccount.create;
      }
    ]
    ++ groupToManifestList webhookGroup
    ++ [
      {
        name = "cert-manager-webhook-mutatingwebhookconfig";
        resource = webhooks.mutating;
        enable = true;
      }
      {
        name = "cert-manager-webhook-validatingwebhookconfig";
        resource = webhooks.validating;
        enable = true;
      }
    ]
    ++ rbac.webhookClusterRbac.toManifestList cfg.rbac.create
    ++ rbac.webhookNamespacedRbac.toManifestList cfg.rbac.create
    # Cainjector: SA + Deployment + Service (gated) + RBAC
    ++ [
      {
        name = "cert-manager-cainjector-sa";
        resource = rbac.cainjectorSa;
        enable = cfg.cainjector.enabled && cfg.serviceAccount.create;
      }
    ]
    ++ withEnable cfg.cainjector.enabled (groupToManifestList cainjectorGroup)
    ++ rbac.cainjectorClusterRbac.toManifestList (cfg.cainjector.enabled && cfg.rbac.create)
    ++ rbac.cainjectorNamespacedRbac.toManifestList (cfg.cainjector.enabled && cfg.rbac.create)
    # Startup API check: SA + Job + RBAC
    ++ [
      {
        name = "cert-manager-startupapicheck-sa";
        resource = rbac.startupapicheckSa;
        enable = cfg.startupapicheck.enabled && cfg.serviceAccount.create;
      }
      {
        name = "cert-manager-startupapicheck-job";
        resource = startupapicheckJob;
        enable = cfg.startupapicheck.enabled;
      }
    ]
    ++ rbac.startupapicheckRbac.toManifestList (cfg.startupapicheck.enabled && cfg.rbac.create);

  extraConfig = {
    # Level 2: service registry
    registry.cert-manager = {
      endpoints = {
        webhook = {
          host = kixlib.mkFqdn {
            name = "cert-manager-webhook";
            namespace = cfg.namespace;
            clusterDomain = cfg.clusterDomain;
          };
          port = 443;
          protocol = "https";
        };
        metrics = {
          host = kixlib.mkFqdn {
            name = "cert-manager";
            namespace = cfg.namespace;
            clusterDomain = cfg.clusterDomain;
          };
          port = 9402;
          protocol = "http";
        };
      };
    };

    # V4 capability: monitoring targets.
    # Controller and webhook are unconditional — no mkIf needed.
    # Cainjector guard MUST match cainjectorMonitoringLabels guard in helpers.nix
    # (doc 12 rule #10).
    capabilities.monitoring.cert-manager = {
      serviceName = "cert-manager";
      namespace = cfg.namespace;
      portName = "tcp-prometheus-servicemonitor";
      port = 9402;
      path = "/metrics";
      selector = controllerLabels.selector;
    };
    capabilities.monitoring.cert-manager-webhook = {
      serviceName = "cert-manager-webhook";
      namespace = cfg.namespace;
      portName = "metrics";
      port = 9402;
      path = "/metrics";
      selector = webhookLabels.selector;
    };
    capabilities.monitoring.cert-manager-cainjector = lib.mkIf cfg.cainjector.enabled {
      serviceName = "cert-manager-cainjector";
      namespace = cfg.namespace;
      portName = "http-metrics";
      port = 9402;
      path = "/metrics";
      selector = cainjectorLabels.selector;
    };
  };
}
