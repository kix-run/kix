# cert-manager resource construction and config wiring.
#
# Plain function called by mkChartModule. Returns { manifestList, extraConfig }.
#
# Source Helm chart: jetstack/cert-manager (v1.19.4)
# Components: controller, webhook, cainjector, startupapicheck

{ lib, config, kixlib, kixlib', cfg, labels, ... }:

let
  fullname = "cert-manager";

  # --- Component labels ---
  # Cert-manager uses different app.kubernetes.io/name per component.
  mkComponentLabels = component: let
    appName = if component == "controller" then "cert-manager" else component;
    base = kixlib.mkLabels {
      chart = appName;
      clusterLabels = config.cluster.labels;
      extra = {
        app = appName;
        "app.kubernetes.io/component" = component;
      };
    };
  in base // {
    selector = base.selector // { "app.kubernetes.io/component" = component; };
  };

  controllerLabels = mkComponentLabels "controller";
  webhookLabels = mkComponentLabels "webhook";
  cainjectorLabels = mkComponentLabels "cainjector";
  startupapicheckLabels = mkComponentLabels "startupapicheck";

  # --- Shared helpers ---
  podSecurityContext = {
    runAsNonRoot = cfg.securityContext.runAsNonRoot;
    runAsUser = cfg.securityContext.runAsUser;
    runAsGroup = cfg.securityContext.runAsGroup;
    fsGroup = cfg.securityContext.fsGroup;
    seccompProfile = { type = cfg.securityContext.seccompProfile.type; };
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

  podNamespaceEnv = { name = "POD_NAMESPACE"; valueFrom.fieldRef.fieldPath = "metadata.namespace"; };

  prometheusAnnotations = lib.optionalAttrs cfg.prometheus.enabled {
    "prometheus.io/path" = "/metrics";
    "prometheus.io/scrape" = "true";
    "prometheus.io/port" = "9402";
  };

  nodeSelector = { "kubernetes.io/os" = "linux"; };

  # ============================================================================
  # CONTROLLER
  # ============================================================================

  controllerSa = kixlib'.rbac.mkServiceAccount {
    metadata = { name = "cert-manager"; labels = controllerLabels.all // { "app.kubernetes.io/component" = "controller"; }; };
    automountServiceAccountToken = cfg.serviceAccount.automountServiceAccountToken;
  };

  controllerContainer = kixlib'.pod.mkContainer {
    name = "cert-manager-controller";
    image = kixlib.imageRef cfg.image;
    imagePullPolicy = cfg.image.pullPolicy;
    args = [
      "--v=${toString cfg.logLevel}"
      "--cluster-resource-namespace=$(POD_NAMESPACE)"
      "--leader-election-namespace=${cfg.leaderElection.namespace}"
      "--acme-http01-solver-image=${kixlib.imageRef cfg.acmeSolverImage}"
      "--max-concurrent-challenges=${toString cfg.maxConcurrentChallenges}"
    ];
    ports = [
      { containerPort = 9402; protocol = "TCP"; name = "http-metrics"; }
      { containerPort = 9403; protocol = "TCP"; name = "http-healthz"; }
    ];
    securityContext = containerSecCtx;
    resources = cfg.resources;
    env = [ podNamespaceEnv ];
    livenessProbe = {
      httpGet = { path = "/livez"; port = "http-healthz"; scheme = "HTTP"; };
      initialDelaySeconds = 10; periodSeconds = 10; timeoutSeconds = 15;
      failureThreshold = 8; successThreshold = 1;
    };
  };

  controllerDeployment = kixlib'.workload.mkDeployment {
    metadata = { name = "cert-manager"; };
    replicas = cfg.replicaCount;
    selectorLabels = controllerLabels.selector // { "app.kubernetes.io/component" = "controller"; };
    template = kixlib'.pod.mkPodTemplate {
      metadata = {
        labels = controllerLabels.all // { "app.kubernetes.io/component" = "controller"; };
        annotations = prometheusAnnotations;
      };
      spec = {
        containers = [ controllerContainer ];
        serviceAccountName = "cert-manager";
        enableServiceLinks = false;
        securityContext = podSecurityContext;
        inherit nodeSelector;
      };
    };
  };

  # Capability output labels for cert-manager Services.
  # Controller and webhook targets are unconditional (no mkIf), so their output
  # can be read without guards. Cainjector needs a guard on cfg.cainjector.enabled.
  # Guard conditions MUST match the corresponding capability declarations below (doc 12 rule #10).
  controllerMonitoringLabels = config.capabilities.monitoring.cert-manager.output.labels;
  controllerMonitoringAnnotations = config.capabilities.monitoring.cert-manager.output.annotations;
  webhookMonitoringLabels = config.capabilities.monitoring.cert-manager-webhook.output.labels;
  webhookMonitoringAnnotations = config.capabilities.monitoring.cert-manager-webhook.output.annotations;
  cainjectorMonitoringLabels =
    if cfg.cainjector.enabled
    then config.capabilities.monitoring.cert-manager-cainjector.output.labels
    else {};
  cainjectorMonitoringAnnotations =
    if cfg.cainjector.enabled
    then config.capabilities.monitoring.cert-manager-cainjector.output.annotations
    else {};

  controllerService = kixlib'.networking.mkService {
    metadata = {
      name = "cert-manager";
      labels = controllerLabels.all // { "app.kubernetes.io/component" = "controller"; } // controllerMonitoringLabels;
      annotations = controllerMonitoringAnnotations;
    };
    spec = {
      type = "ClusterIP";
      ports = [
        { port = 9402; protocol = "TCP"; targetPort = "http-metrics"; name = "tcp-prometheus-servicemonitor"; }
      ];
      selector = controllerLabels.selector // { "app.kubernetes.io/component" = "controller"; };
    };
  };

  # --- Controller RBAC ---
  # Uses mkRoleSet to batch-generate 8 ClusterRoles + 8 ClusterRoleBindings,
  # eliminating ~80 lines of repeated subjects/binding boilerplate.
  controllerSubjects = kixlib.rbac.subjects.sa { name = "cert-manager"; namespace = cfg.namespace; };

  controllerRbac = kixlib'.rbac.mkRoleSet {
    subjects = controllerSubjects;
    roles = {
      "cert-manager-controller-issuers" = { rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "issuers" "issuers/status" ]; verbs = [ "update" "patch" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "issuers" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" "create" "update" "delete" ]; }
        { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "create" "patch" ]; }
      ]; };
      "cert-manager-controller-clusterissuers" = { rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "clusterissuers" "clusterissuers/status" ]; verbs = [ "update" "patch" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "clusterissuers" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" "create" "update" "delete" ]; }
        { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "create" "patch" ]; }
      ]; };
      "cert-manager-controller-certificates" = { rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" "certificates/status" "certificaterequests" "certificaterequests/status" ]; verbs = [ "update" "patch" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" "certificaterequests" "clusterissuers" "issuers" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates/finalizers" "certificaterequests/finalizers" ]; verbs = [ "update" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "orders" ]; verbs = [ "create" "delete" "get" "list" "watch" ]; }
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" "create" "update" "delete" "patch" ]; }
        { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "create" "patch" ]; }
      ]; };
      "cert-manager-controller-orders" = { rules = [
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "orders" "orders/status" ]; verbs = [ "update" "patch" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "orders" "challenges" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "clusterissuers" "issuers" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "challenges" ]; verbs = [ "create" "delete" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "orders/finalizers" ]; verbs = [ "update" ]; }
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "create" "patch" ]; }
      ]; };
      "cert-manager-controller-challenges" = { rules = [
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "challenges" "challenges/status" ]; verbs = [ "update" "patch" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "challenges" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "issuers" "clusterissuers" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "create" "patch" ]; }
        { apiGroups = [ "" ]; resources = [ "pods" "services" ]; verbs = [ "get" "list" "watch" "create" "delete" ]; }
        { apiGroups = [ "networking.k8s.io" ]; resources = [ "ingresses" ]; verbs = [ "get" "list" "watch" "create" "delete" "update" ]; }
        { apiGroups = [ "gateway.networking.k8s.io" ]; resources = [ "httproutes" ]; verbs = [ "get" "list" "watch" "create" "delete" "update" ]; }
        { apiGroups = [ "route.openshift.io" ]; resources = [ "routes/custom-host" ]; verbs = [ "create" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "challenges/finalizers" ]; verbs = [ "update" ]; }
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" ]; }
      ]; };
      "cert-manager-controller-ingress-shim" = { rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" "certificaterequests" ]; verbs = [ "create" "update" "delete" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" "certificaterequests" "issuers" "clusterissuers" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "networking.k8s.io" ]; resources = [ "ingresses" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "networking.k8s.io" ]; resources = [ "ingresses/finalizers" ]; verbs = [ "update" ]; }
        { apiGroups = [ "gateway.networking.k8s.io" ]; resources = [ "gateways" "httproutes" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "gateway.networking.k8s.io" ]; resources = [ "gateways/finalizers" "httproutes/finalizers" ]; verbs = [ "update" ]; }
        { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "create" "patch" ]; }
      ]; };
      "cert-manager-controller-approve:cert-manager-io" = {
        metadata.labels = controllerLabels.all // { "app.kubernetes.io/component" = "cert-manager"; };
        rules = [
          { apiGroups = [ "cert-manager.io" ]; resources = [ "signers" ]; verbs = [ "approve" ];
            resourceNames = [ "issuers.cert-manager.io/*" "clusterissuers.cert-manager.io/*" ]; }
        ];
      };
      "cert-manager-controller-certificatesigningrequests" = {
        metadata.labels = controllerLabels.all // { "app.kubernetes.io/component" = "cert-manager"; };
        rules = [
          { apiGroups = [ "certificates.k8s.io" ]; resources = [ "certificatesigningrequests" ]; verbs = [ "get" "list" "watch" "update" ]; }
          { apiGroups = [ "certificates.k8s.io" ]; resources = [ "certificatesigningrequests/status" ]; verbs = [ "update" "patch" ]; }
          { apiGroups = [ "certificates.k8s.io" ]; resources = [ "signers" ]; verbs = [ "sign" ];
            resourceNames = [ "issuers.cert-manager.io/*" "clusterissuers.cert-manager.io/*" ]; }
          { apiGroups = [ "authorization.k8s.io" ]; resources = [ "subjectaccessreviews" ]; verbs = [ "create" ]; }
        ];
      };
    };
  };

  # Aggregated ClusterRoles — no bindings, only roles with aggregation labels.
  aggregatedClusterRoles = {
    cluster-view = kixlib'.rbac.mkClusterRole {
      metadata = { name = "cert-manager-cluster-view";
        labels = controllerLabels.all // { "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true"; }; };
      rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "clusterissuers" ]; verbs = [ "get" "list" "watch" ]; }
      ];
    };
    view = kixlib'.rbac.mkClusterRole {
      metadata = { name = "cert-manager-view";
        labels = controllerLabels.all // {
          "rbac.authorization.k8s.io/aggregate-to-view" = "true";
          "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
          "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
          "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
        }; };
      rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" "certificaterequests" "issuers" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "challenges" "orders" ]; verbs = [ "get" "list" "watch" ]; }
      ];
    };
    edit = kixlib'.rbac.mkClusterRole {
      metadata = { name = "cert-manager-edit";
        labels = controllerLabels.all // {
          "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
          "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
        }; };
      rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" "certificaterequests" "issuers" ]; verbs = [ "create" "delete" "deletecollection" "patch" "update" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates/status" ]; verbs = [ "update" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "challenges" "orders" ]; verbs = [ "create" "delete" "deletecollection" "patch" "update" ]; }
      ];
    };
  };

  # Controller namespace-scoped roles — leader election + tokenrequest.
  # These use mkRoleSet with scope = "namespace" for batch generation.
  controllerNamespacedRbac = kixlib'.rbac.mkRoleSet {
    subjects = controllerSubjects;
    scope = "namespace";
    roles = {
      "cert-manager:leaderelection" = {
        metadata = { namespace = cfg.leaderElection.namespace;
          labels = controllerLabels.all // { "app.kubernetes.io/component" = "controller"; }; };
        rules = [
          { apiGroups = [ "coordination.k8s.io" ]; resources = [ "leases" ]; verbs = [ "get" "update" "patch" ];
            resourceNames = [ "cert-manager-controller" ]; }
          { apiGroups = [ "coordination.k8s.io" ]; resources = [ "leases" ]; verbs = [ "create" ]; }
        ];
      };
      "cert-manager-tokenrequest" = {
        metadata.labels = controllerLabels.all // { "app.kubernetes.io/component" = "controller"; };
        rules = [
          { apiGroups = [ "" ]; resources = [ "serviceaccounts/token" ]; verbs = [ "create" ];
            resourceNames = [ "cert-manager" ]; }
        ];
      };
    };
  };

  # ============================================================================
  # WEBHOOK
  # ============================================================================

  webhookSa = kixlib'.rbac.mkServiceAccount {
    metadata = { name = "cert-manager-webhook"; labels = webhookLabels.all; };
    automountServiceAccountToken = cfg.serviceAccount.automountServiceAccountToken;
  };

  webhookContainer = kixlib'.pod.mkContainer {
    name = "cert-manager-webhook";
    image = kixlib.imageRef cfg.webhook.image;
    imagePullPolicy = cfg.webhook.image.pullPolicy;
    args = [
      "--v=${toString cfg.logLevel}"
      "--secure-port=${toString cfg.webhook.securePort}"
      "--dynamic-serving-ca-secret-namespace=$(POD_NAMESPACE)"
      "--dynamic-serving-ca-secret-name=cert-manager-webhook-ca"
      "--dynamic-serving-dns-names=cert-manager-webhook"
      "--dynamic-serving-dns-names=cert-manager-webhook.$(POD_NAMESPACE)"
      "--dynamic-serving-dns-names=cert-manager-webhook.$(POD_NAMESPACE).svc"
    ];
    ports = [
      { containerPort = cfg.webhook.securePort; protocol = "TCP"; name = "https"; }
      { containerPort = 6080; protocol = "TCP"; name = "healthcheck"; }
      { containerPort = 9402; protocol = "TCP"; name = "http-metrics"; }
    ];
    securityContext = containerSecCtx;
    resources = cfg.webhook.resources;
    env = [ podNamespaceEnv ];
    livenessProbe = {
      httpGet = { path = "/livez"; port = "healthcheck"; scheme = "HTTP"; };
      initialDelaySeconds = 60; periodSeconds = 10; timeoutSeconds = 1;
      failureThreshold = 3; successThreshold = 1;
    };
    readinessProbe = {
      httpGet = { path = "/healthz"; port = "healthcheck"; scheme = "HTTP"; };
      initialDelaySeconds = 5; periodSeconds = 5; timeoutSeconds = 1;
      failureThreshold = 3; successThreshold = 1;
    };
  };

  webhookDeployment = kixlib'.workload.mkDeployment {
    metadata = { name = "cert-manager-webhook"; labels = webhookLabels.all; };
    replicas = cfg.webhook.replicaCount;
    selectorLabels = webhookLabels.selector;
    template = kixlib'.pod.mkPodTemplate {
      metadata = { labels = webhookLabels.all; annotations = prometheusAnnotations; };
      spec = {
        containers = [ webhookContainer ];
        serviceAccountName = "cert-manager-webhook";
        enableServiceLinks = false;
        securityContext = podSecurityContext;
        inherit nodeSelector;
      };
    };
  };

  webhookService = kixlib'.networking.mkService {
    metadata = {
      name = "cert-manager-webhook";
      labels = webhookLabels.all // webhookMonitoringLabels;
      annotations = webhookMonitoringAnnotations;
    };
    spec = {
      type = "ClusterIP";
      ports = [
        { port = 443; protocol = "TCP"; targetPort = "https"; name = "https"; }
        { port = 9402; protocol = "TCP"; targetPort = "http-metrics"; name = "metrics"; }
      ];
      selector = webhookLabels.selector;
    };
  };

  webhookSubjects = kixlib.rbac.subjects.sa { name = "cert-manager-webhook"; namespace = cfg.namespace; };

  webhookClusterRbac = kixlib'.rbac.mkRoleSet {
    subjects = webhookSubjects;
    metadata.labels = webhookLabels.all;
    roles = {
      "cert-manager-webhook:subjectaccessreviews" = { rules = [
        { apiGroups = [ "authorization.k8s.io" ]; resources = [ "subjectaccessreviews" ]; verbs = [ "create" ]; }
      ]; };
    };
  };

  webhookNamespacedRbac = kixlib'.rbac.mkRoleSet {
    subjects = webhookSubjects;
    scope = "namespace";
    metadata.labels = webhookLabels.all;
    roles = {
      "cert-manager-webhook:dynamic-serving" = { rules = [
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" "update" ];
          resourceNames = [ "cert-manager-webhook-ca" ]; }
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "create" ]; }
      ]; };
    };
  };

  mutatingWebhook = kixlib'.admission.mkMutatingWebhookConfiguration {
    metadata = { name = "cert-manager-webhook"; labels = webhookLabels.all;
      annotations = { "cert-manager.io/inject-ca-from-secret" = "${cfg.namespace}/cert-manager-webhook-ca"; }; };
    webhooks = [{
      name = "webhook.cert-manager.io";
      rules = [{ apiGroups = [ "cert-manager.io" ]; apiVersions = [ "v1" ]; operations = [ "CREATE" ]; resources = [ "certificaterequests" ]; }];
      admissionReviewVersions = [ "v1" ]; matchPolicy = "Equivalent";
      timeoutSeconds = cfg.webhook.timeoutSeconds; failurePolicy = "Fail"; sideEffects = "None";
      clientConfig.service = { name = "cert-manager-webhook"; namespace = cfg.namespace; path = "/mutate"; };
    }];
  };

  validatingWebhook = kixlib'.admission.mkValidatingWebhookConfiguration {
    metadata = { name = "cert-manager-webhook"; labels = webhookLabels.all;
      annotations = { "cert-manager.io/inject-ca-from-secret" = "${cfg.namespace}/cert-manager-webhook-ca"; }; };
    webhooks = [{
      name = "webhook.cert-manager.io";
      namespaceSelector.matchExpressions = [{ key = "cert-manager.io/disable-validation"; operator = "NotIn"; values = [ "true" ]; }];
      rules = [{ apiGroups = [ "cert-manager.io" "acme.cert-manager.io" ]; apiVersions = [ "v1" ]; operations = [ "CREATE" "UPDATE" ]; resources = [ "*/*" ]; }];
      admissionReviewVersions = [ "v1" ]; matchPolicy = "Equivalent";
      timeoutSeconds = cfg.webhook.timeoutSeconds; failurePolicy = "Fail"; sideEffects = "None";
      clientConfig.service = { name = "cert-manager-webhook"; namespace = cfg.namespace; path = "/validate"; };
    }];
  };

  # ============================================================================
  # CA INJECTOR
  # ============================================================================

  cainjectorSa = kixlib'.rbac.mkServiceAccount {
    metadata = { name = "cert-manager-cainjector"; labels = cainjectorLabels.all; };
    automountServiceAccountToken = cfg.serviceAccount.automountServiceAccountToken;
  };

  cainjectorContainer = kixlib'.pod.mkContainer {
    name = "cert-manager-cainjector";
    image = kixlib.imageRef cfg.cainjector.image;
    imagePullPolicy = cfg.cainjector.image.pullPolicy;
    args = [ "--v=${toString cfg.logLevel}" "--leader-election-namespace=${cfg.leaderElection.namespace}" ];
    ports = [{ containerPort = 9402; protocol = "TCP"; name = "http-metrics"; }];
    securityContext = containerSecCtx;
    resources = cfg.cainjector.resources;
    env = [ podNamespaceEnv ];
  };

  cainjectorDeployment = kixlib'.workload.mkDeployment {
    metadata = { name = "cert-manager-cainjector"; labels = cainjectorLabels.all; };
    replicas = cfg.cainjector.replicaCount;
    selectorLabels = cainjectorLabels.selector;
    template = kixlib'.pod.mkPodTemplate {
      metadata = { labels = cainjectorLabels.all; annotations = prometheusAnnotations; };
      spec = {
        containers = [ cainjectorContainer ];
        serviceAccountName = "cert-manager-cainjector";
        enableServiceLinks = false;
        securityContext = podSecurityContext;
        inherit nodeSelector;
      };
    };
  };

  cainjectorService = kixlib'.networking.mkService {
    metadata = {
      name = "cert-manager-cainjector";
      labels = cainjectorLabels.all // cainjectorMonitoringLabels;
      annotations = cainjectorMonitoringAnnotations;
    };
    spec = {
      type = "ClusterIP";
      ports = [{ port = 9402; protocol = "TCP"; name = "http-metrics"; }];
      selector = cainjectorLabels.selector;
    };
  };

  cainjectorSubjects = kixlib.rbac.subjects.sa { name = "cert-manager-cainjector"; namespace = cfg.namespace; };

  cainjectorClusterRbac = kixlib'.rbac.mkRoleSet {
    subjects = cainjectorSubjects;
    metadata.labels = cainjectorLabels.all;
    roles = {
      "cert-manager-cainjector" = { rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "get" "create" "update" "patch" ]; }
        { apiGroups = [ "admissionregistration.k8s.io" ]; resources = [ "validatingwebhookconfigurations" "mutatingwebhookconfigurations" ]; verbs = [ "get" "list" "watch" "update" "patch" ]; }
        { apiGroups = [ "apiregistration.k8s.io" ]; resources = [ "apiservices" ]; verbs = [ "get" "list" "watch" "update" "patch" ]; }
        { apiGroups = [ "apiextensions.k8s.io" ]; resources = [ "customresourcedefinitions" ]; verbs = [ "get" "list" "watch" "update" "patch" ]; }
      ]; };
    };
  };

  cainjectorNamespacedRbac = kixlib'.rbac.mkRoleSet {
    subjects = cainjectorSubjects;
    scope = "namespace";
    metadata.labels = cainjectorLabels.all;
    roles = {
      "cert-manager-cainjector:leaderelection" = {
        metadata.namespace = cfg.leaderElection.namespace;
        rules = [
          { apiGroups = [ "coordination.k8s.io" ]; resources = [ "leases" ]; verbs = [ "get" "update" "patch" ];
            resourceNames = [ "cert-manager-cainjector-leader-election" "cert-manager-cainjector-leader-election-core" ]; }
          { apiGroups = [ "coordination.k8s.io" ]; resources = [ "leases" ]; verbs = [ "create" ]; }
        ];
      };
    };
  };

  # ============================================================================
  # STARTUP API CHECK
  # ============================================================================

  startupapicheckSa = kixlib'.rbac.mkServiceAccount {
    metadata = { name = "cert-manager-startupapicheck"; labels = startupapicheckLabels.all; };
    automountServiceAccountToken = cfg.serviceAccount.automountServiceAccountToken;
  };

  startupapicheckJob = kixlib'.workload.mkJob {
    metadata = { name = "cert-manager-startupapicheck"; labels = startupapicheckLabels.all; };
    backoffLimit = 4;
    template = kixlib'.pod.mkPodTemplate {
      metadata = { labels = startupapicheckLabels.all; };
      spec = {
        restartPolicy = "OnFailure";
        containers = [
          (kixlib'.pod.mkContainer {
            name = "cert-manager-startupapicheck";
            image = kixlib.imageRef cfg.startupapicheck.image;
            imagePullPolicy = cfg.startupapicheck.image.pullPolicy;
            args = [ "check" "api" "--wait=1m" "-v" ];
            securityContext = containerSecCtx;
            resources = cfg.startupapicheck.resources;
            env = [ podNamespaceEnv ];
          })
        ];
        serviceAccountName = "cert-manager-startupapicheck";
        enableServiceLinks = false;
        securityContext = podSecurityContext;
        inherit nodeSelector;
      };
    };
  };

  startupapicheckRbac = kixlib'.rbac.mkRoleSet {
    subjects = kixlib.rbac.subjects.sa { name = "cert-manager-startupapicheck"; namespace = cfg.namespace; };
    scope = "namespace";
    metadata.labels = startupapicheckLabels.all;
    roles = {
      "cert-manager-startupapicheck:create-cert" = { rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificaterequests" ]; verbs = [ "create" ]; }
      ]; };
    };
  };

in
{
  manifestList =
    [
      { name = "cert-manager-sa"; resource = controllerSa; enable = cfg.serviceAccount.create; }
      { name = "cert-manager-deployment"; resource = controllerDeployment; enable = true; }
      { name = "cert-manager-service"; resource = controllerService; enable = true; }
    ]
    # Controller cluster RBAC — 8 ClusterRoles + 8 ClusterRoleBindings via mkRoleSet
    ++ controllerRbac.toManifestList cfg.rbac.create
    # Aggregated ClusterRoles — no bindings, just roles with aggregation labels
    ++ lib.mapAttrsToList (n: role:
      { name = "cert-manager-clusterrole-${n}"; resource = role; enable = cfg.rbac.create && cfg.rbac.aggregateClusterRoles; }
    ) aggregatedClusterRoles
    # Controller namespace-scoped RBAC (leader election + tokenrequest)
    ++ controllerNamespacedRbac.toManifestList cfg.rbac.create
    ++ [
      { name = "cert-manager-webhook-sa"; resource = webhookSa; enable = cfg.serviceAccount.create; }
      { name = "cert-manager-webhook-deployment"; resource = webhookDeployment; enable = true; }
      { name = "cert-manager-webhook-service"; resource = webhookService; enable = true; }
      { name = "cert-manager-webhook-mutatingwebhookconfig"; resource = mutatingWebhook; enable = true; }
      { name = "cert-manager-webhook-validatingwebhookconfig"; resource = validatingWebhook; enable = true; }
    ]
    # Webhook RBAC
    ++ webhookClusterRbac.toManifestList cfg.rbac.create
    ++ webhookNamespacedRbac.toManifestList cfg.rbac.create
    ++ [
      { name = "cert-manager-cainjector-sa"; resource = cainjectorSa; enable = cfg.cainjector.enabled && cfg.serviceAccount.create; }
      { name = "cert-manager-cainjector-deployment"; resource = cainjectorDeployment; enable = cfg.cainjector.enabled; }
      { name = "cert-manager-cainjector-service"; resource = cainjectorService; enable = cfg.cainjector.enabled; }
    ]
    # Cainjector RBAC
    ++ cainjectorClusterRbac.toManifestList (cfg.cainjector.enabled && cfg.rbac.create)
    ++ cainjectorNamespacedRbac.toManifestList (cfg.cainjector.enabled && cfg.rbac.create)
    ++ [
      { name = "cert-manager-startupapicheck-sa"; resource = startupapicheckSa; enable = cfg.startupapicheck.enabled && cfg.serviceAccount.create; }
      { name = "cert-manager-startupapicheck-job"; resource = startupapicheckJob; enable = cfg.startupapicheck.enabled; }
    ]
    # Startupapicheck RBAC
    ++ startupapicheckRbac.toManifestList (cfg.startupapicheck.enabled && cfg.rbac.create);

  extraConfig = {
    # Level 2: service registry
    registry.cert-manager = {
      endpoints = {
        webhook = {
          host = kixlib.mkFqdn { name = "cert-manager-webhook"; namespace = cfg.namespace; clusterDomain = cfg.clusterDomain; };
          port = 443;
          protocol = "https";
        };
        metrics = {
          host = kixlib.mkFqdn { name = "cert-manager"; namespace = cfg.namespace; clusterDomain = cfg.clusterDomain; };
          port = 9402;
          protocol = "http";
        };
      };
    };

    # V4 capability: monitoring targets
    # Controller and webhook are unconditional — no mkIf needed.
    # Cainjector is gated on cfg.cainjector.enabled. The guard on
    # cainjectorMonitoringLabels/cainjectorMonitoringAnnotations above MUST match
    # this mkIf condition exactly (doc 12 rule #10).
    capabilities.monitoring.cert-manager = {
      serviceName = "cert-manager";
      namespace = cfg.namespace;
      portName = "tcp-prometheus-servicemonitor";
      port = 9402;  # Known duplication with container spec — unavoidable without withMetrics
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
