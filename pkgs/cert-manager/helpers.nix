# cert-manager package-specific helpers.
#
# Contains: component label factory, shared security contexts, monitoring guards,
# mkComponent helper wrapping mkServiceDeployment for cert-manager's 3 near-identical
# components (controller, webhook, cainjector).

{
  lib,
  config,
  kixlib,
  kixlib',
  cfg,
  ...
}:

let
  # --- Component labels ---
  # Cert-manager uses different app.kubernetes.io/name per component.
  mkComponentLabels =
    component:
    let
      appName = if component == "controller" then "cert-manager" else component;
      base = kixlib.mkLabels {
        chart = appName;
        clusterLabels = config.cluster.labels;
        extra = {
          app = appName;
          "app.kubernetes.io/component" = component;
        };
      };
    in
    base
    // {
      selector = base.selector // {
        "app.kubernetes.io/component" = component;
      };
    };

  controllerLabels = mkComponentLabels "controller";
  webhookLabels = mkComponentLabels "webhook";
  cainjectorLabels = mkComponentLabels "cainjector";
  startupapicheckLabels = mkComponentLabels "startupapicheck";

  # --- Shared security contexts ---
  podSecurityContext = {
    runAsNonRoot = cfg.securityContext.runAsNonRoot;
    runAsUser = cfg.securityContext.runAsUser;
    runAsGroup = cfg.securityContext.runAsGroup;
    fsGroup = cfg.securityContext.fsGroup;
    seccompProfile = {
      type = cfg.securityContext.seccompProfile.type;
    };
  };

  containerSecCtx = {
    allowPrivilegeEscalation = cfg.containerSecurityContext.allowPrivilegeEscalation;
    capabilities = {
      add = cfg.containerSecurityContext.capabilities.add;
      drop = cfg.containerSecurityContext.capabilities.drop;
    };
    readOnlyRootFilesystem = cfg.containerSecurityContext.readOnlyRootFilesystem;
    runAsNonRoot = cfg.containerSecurityContext.runAsNonRoot;
    runAsUser = cfg.containerSecurityContext.runAsUser;
  };

  # --- Shared values ---
  podNamespaceEnv = {
    name = "POD_NAMESPACE";
    valueFrom.fieldRef.fieldPath = "metadata.namespace";
  };

  prometheusAnnotations = lib.optionalAttrs cfg.prometheus.enabled {
    "prometheus.io/path" = "/metrics";
    "prometheus.io/scrape" = "true";
    "prometheus.io/port" = "9402";
  };

  nodeSelector = {
    "kubernetes.io/os" = "linux";
  };

  # --- Monitoring guards ---
  # Capability output labels for cert-manager Services.
  # Controller and webhook targets are unconditional (no mkIf), so their output
  # can be read without guards. Cainjector needs a guard on cfg.cainjector.enabled.
  # Guard conditions MUST match the corresponding capability declarations in
  # resources.nix (doc 12 rule #10).
  controllerMonitoringLabels = config.capabilities.monitoring.cert-manager.output.labels;
  controllerMonitoringAnnotations = config.capabilities.monitoring.cert-manager.output.annotations;
  webhookMonitoringLabels = config.capabilities.monitoring.cert-manager-webhook.output.labels;
  webhookMonitoringAnnotations =
    config.capabilities.monitoring.cert-manager-webhook.output.annotations;
  cainjectorMonitoringLabels =
    if cfg.cainjector.enabled then
      config.capabilities.monitoring.cert-manager-cainjector.output.labels
    else
      { };
  cainjectorMonitoringAnnotations =
    if cfg.cainjector.enabled then
      config.capabilities.monitoring.cert-manager-cainjector.output.annotations
    else
      { };

  # --- mkComponent: wraps mkServiceDeployment for cert-manager's components ---
  # Each component (controller, webhook, cainjector) is a Deployment + Service with
  # the same pod security context, prometheus annotations, and node selector.
  inherit (kixlib'.combinators) mkServiceDeployment;

  mkComponent =
    {
      componentName,
      componentLabels,
      container,
      replicas,
      servicePorts,
      serviceAccountName,
      monitoringLabels ? { },
      monitoringAnnotations ? { },
      deploymentLabels ? { },
    }:
    mkServiceDeployment {
      name = componentName;
      containers = [ container ];
      selectorLabels = componentLabels.selector;
      inherit
        servicePorts
        replicas
        serviceAccountName
        deploymentLabels
        ;
      serviceLabels = componentLabels.all // monitoringLabels;
      serviceAnnotations = monitoringAnnotations;
      podLabels = componentLabels.all;
      podAnnotations = prometheusAnnotations;
      podSpec = {
        enableServiceLinks = false;
        securityContext = podSecurityContext;
        inherit nodeSelector;
      };
    };

in
{
  inherit
    mkComponentLabels
    controllerLabels
    webhookLabels
    cainjectorLabels
    startupapicheckLabels
    podSecurityContext
    containerSecCtx
    podNamespaceEnv
    prometheusAnnotations
    nodeSelector
    controllerMonitoringLabels
    controllerMonitoringAnnotations
    webhookMonitoringLabels
    webhookMonitoringAnnotations
    cainjectorMonitoringLabels
    cainjectorMonitoringAnnotations
    mkComponent
    ;
}
