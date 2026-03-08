# cert-manager resource construction and config wiring.
#
# This file builds all Kubernetes resources for the cert-manager module and wires
# them into config.manifests, config.registry, and config.monitoring.
# Option declarations live in options.nix.
#
# Source Helm chart: jetstack/cert-manager (v1.19.4)
#
# Components: controller, webhook, cainjector, startupapicheck
# Each component section is clearly delimited below.
#
# Key design decisions:
#   - All components share pod/container security contexts (Helm defaults are identical)
#   - Leader election Roles go to cfg.leaderElection.namespace (default kube-system),
#     NOT the chart namespace. These require explicit metadata.namespace override
#     since kixlib'.withMetadata sets the chart namespace.
#   - RBAC names follow Helm convention: "cert-manager-controller-<purpose>" for
#     controller roles, "cert-manager-webhook:<purpose>" for webhook roles, etc.
#   - Webhook caBundle is empty string at deploy time — cainjector fills it at runtime
#     by watching the cert-manager.io/inject-ca-from-secret annotation.
#   - CRDs are NOT generated — standard practice is to install them separately.
#   - Startup API check is a plain Job (no Helm hook annotations since kix doesn't
#     have hooks). Deploy this after CRDs and the controller are running.

{
  lib,
  config,
  kixlib,
  ...
}:

let
  cfg = config.services.cert-manager;

  # --- Naming ---
  # Helm uses "release-name-cert-manager" as base name. We just use "cert-manager".
  fullname = "cert-manager";

  # --- Labels ---
  # Cert-manager's Helm chart uses different app.kubernetes.io/name values per component:
  #   controller: "cert-manager", webhook: "webhook", cainjector: "cainjector",
  #   startupapicheck: "startupapicheck"
  # This is unusual — most Helm charts use the same app name for all components and
  # differentiate only via app.kubernetes.io/component. Cert-manager does both.
  #
  # Why a helper instead of calling kixlib.mkLabels directly for each component:
  # The pattern repeats 4 times and the component→appName mapping (controller→"cert-manager",
  # everything else→component name) is a Helm-specific quirk we need to preserve for parity.
  # Centralizing it prevents subtle label mismatches if a new component is added.
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
    # Override selector to include component for proper pod targeting.
    selector = base.selector // { "app.kubernetes.io/component" = component; };
  };

  # Controller labels are the "default" — used for chart-wide resources.
  labels = mkComponentLabels "controller";
  webhookLabels = mkComponentLabels "webhook";
  cainjectorLabels = mkComponentLabels "cainjector";
  startupapicheckLabels = mkComponentLabels "startupapicheck";

  # --- kixlib setup ---
  kixlib' = kixlib.withMetadata {
    namespace = cfg.namespace;
    labels = labels.all;
    name = fullname;
  };

  # --- Shared helpers ---

  # Pod security context — same defaults for all components.
  # Nullable fields (runAsUser, runAsGroup, fsGroup) pass through as null and are
  # stripped by removeNulls during mkManifest serialization.
  podSecurityContext = {
    runAsNonRoot = cfg.securityContext.runAsNonRoot;
    runAsUser = cfg.securityContext.runAsUser;
    runAsGroup = cfg.securityContext.runAsGroup;
    fsGroup = cfg.securityContext.fsGroup;
    seccompProfile = {
      type = cfg.securityContext.seccompProfile.type;
    };
  };

  # Container security context — same defaults for all components.
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

  # POD_NAMESPACE env var — used by all components for self-referencing.
  podNamespaceEnv = {
    name = "POD_NAMESPACE";
    valueFrom.fieldRef.fieldPath = "metadata.namespace";
  };

  # Prometheus annotations for Services (when cfg.prometheus.enabled).
  prometheusAnnotations = lib.optionalAttrs cfg.prometheus.enabled {
    "prometheus.io/path" = "/metrics";
    "prometheus.io/scrape" = "true";
    "prometheus.io/port" = "9402";
  };

  # Node selector — Helm defaults to kubernetes.io/os: linux for all components.
  nodeSelector = { "kubernetes.io/os" = "linux"; };

  # ============================================================================
  # CONTROLLER COMPONENT
  # ============================================================================

  controllerSa = kixlib'.rbac.mkServiceAccount {
    metadata = { name = "cert-manager"; labels = labels.all // { "app.kubernetes.io/component" = "controller"; }; };
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
      initialDelaySeconds = 10;
      periodSeconds = 10;
      timeoutSeconds = 15;
      failureThreshold = 8;
      successThreshold = 1;
    };
  };

  controllerDeployment = kixlib'.workload.mkDeployment {
    metadata = { name = "cert-manager"; };
    replicas = cfg.replicaCount;
    selectorLabels = labels.selector // { "app.kubernetes.io/component" = "controller"; };
    template = kixlib'.pod.mkPodTemplate {
      metadata = {
        labels = labels.all // { "app.kubernetes.io/component" = "controller"; };
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

  controllerService = kixlib'.networking.mkService {
    metadata = {
      name = "cert-manager";
      labels = labels.all // { "app.kubernetes.io/component" = "controller"; };
    };
    spec = {
      type = "ClusterIP";
      ports = [
        { port = 9402; protocol = "TCP"; targetPort = "http-metrics"; name = "tcp-prometheus-servicemonitor"; }
      ];
      selector = labels.selector // { "app.kubernetes.io/component" = "controller"; };
    };
  };

  # --- Controller RBAC ---
  # 8 core ClusterRoles + 8 ClusterRoleBindings + 3 aggregated ClusterRoles
  # + 2 Roles + 2 RoleBindings (leader election + tokenrequest)

  controllerClusterRoles = {
    issuers = kixlib'.rbac.mkClusterRole {
      metadata = { name = "cert-manager-controller-issuers"; };
      rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "issuers" "issuers/status" ]; verbs = [ "update" "patch" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "issuers" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" "create" "update" "delete" ]; }
        { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "create" "patch" ]; }
      ];
    };

    clusterissuers = kixlib'.rbac.mkClusterRole {
      metadata = { name = "cert-manager-controller-clusterissuers"; };
      rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "clusterissuers" "clusterissuers/status" ]; verbs = [ "update" "patch" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "clusterissuers" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" "create" "update" "delete" ]; }
        { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "create" "patch" ]; }
      ];
    };

    certificates = kixlib'.rbac.mkClusterRole {
      metadata = { name = "cert-manager-controller-certificates"; };
      rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" "certificates/status" "certificaterequests" "certificaterequests/status" ]; verbs = [ "update" "patch" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" "certificaterequests" "clusterissuers" "issuers" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates/finalizers" "certificaterequests/finalizers" ]; verbs = [ "update" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "orders" ]; verbs = [ "create" "delete" "get" "list" "watch" ]; }
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" "create" "update" "delete" "patch" ]; }
        { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "create" "patch" ]; }
      ];
    };

    orders = kixlib'.rbac.mkClusterRole {
      metadata = { name = "cert-manager-controller-orders"; };
      rules = [
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "orders" "orders/status" ]; verbs = [ "update" "patch" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "orders" "challenges" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "clusterissuers" "issuers" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "challenges" ]; verbs = [ "create" "delete" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "orders/finalizers" ]; verbs = [ "update" ]; }
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "create" "patch" ]; }
      ];
    };

    challenges = kixlib'.rbac.mkClusterRole {
      metadata = { name = "cert-manager-controller-challenges"; };
      rules = [
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
        # DNS01 rules — Helm duplicates the secrets rule here for clarity.
        # Keeping for parity even though it's functionally redundant with rule above.
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" ]; }
      ];
    };

    ingress-shim = kixlib'.rbac.mkClusterRole {
      metadata = { name = "cert-manager-controller-ingress-shim"; };
      rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" "certificaterequests" ]; verbs = [ "create" "update" "delete" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" "certificaterequests" "issuers" "clusterissuers" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "networking.k8s.io" ]; resources = [ "ingresses" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "networking.k8s.io" ]; resources = [ "ingresses/finalizers" ]; verbs = [ "update" ]; }
        { apiGroups = [ "gateway.networking.k8s.io" ]; resources = [ "gateways" "httproutes" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "gateway.networking.k8s.io" ]; resources = [ "gateways/finalizers" "httproutes/finalizers" ]; verbs = [ "update" ]; }
        { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "create" "patch" ]; }
      ];
    };

    # Note: Helm uses component "cert-manager" (not "controller") for these two roles
    # because the template uses `{{ template "cert-manager.name" . }}` as component.
    approve = kixlib'.rbac.mkClusterRole {
      metadata = { name = "cert-manager-controller-approve:cert-manager-io";
        labels = labels.all // { "app.kubernetes.io/component" = "cert-manager"; }; };
      rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "signers" ]; verbs = [ "approve" ];
          resourceNames = [ "issuers.cert-manager.io/*" "clusterissuers.cert-manager.io/*" ]; }
      ];
    };

    certificatesigningrequests = kixlib'.rbac.mkClusterRole {
      metadata = { name = "cert-manager-controller-certificatesigningrequests";
        labels = labels.all // { "app.kubernetes.io/component" = "cert-manager"; }; };
      rules = [
        { apiGroups = [ "certificates.k8s.io" ]; resources = [ "certificatesigningrequests" ]; verbs = [ "get" "list" "watch" "update" ]; }
        { apiGroups = [ "certificates.k8s.io" ]; resources = [ "certificatesigningrequests/status" ]; verbs = [ "update" "patch" ]; }
        { apiGroups = [ "certificates.k8s.io" ]; resources = [ "signers" ]; verbs = [ "sign" ];
          resourceNames = [ "issuers.cert-manager.io/*" "clusterissuers.cert-manager.io/*" ]; }
        { apiGroups = [ "authorization.k8s.io" ]; resources = [ "subjectaccessreviews" ]; verbs = [ "create" ]; }
      ];
    };
  };

  # ClusterRoleBindings — one per core ClusterRole, all bind to controller SA.
  # Each needs an explicit metadata.name matching the ClusterRole name, otherwise
  # they'd all inherit the default name from withMetadata ("cert-manager").
  controllerClusterRoleBindings = lib.mapAttrs (name: role:
    kixlib'.rbac.mkClusterRoleBindingWith {
      clusterRole = role;
      serviceAccount = controllerSa;
      metadata = {
        name = kixlib.resourceName role;
        # Inherit labels from the ClusterRole — approve and CSR have component "cert-manager"
        # while others have component "controller".
        labels = role.metadata.labels or labels.all;
      };
      subjects = [{
        kind = "ServiceAccount";
        name = "cert-manager";
        namespace = cfg.namespace;
      }];
    }
  ) controllerClusterRoles;

  # Aggregated ClusterRoles — conditional on cfg.rbac.aggregateClusterRoles.
  # These add cert-manager permissions to K8s default user-facing roles (view, edit, admin).
  aggregatedClusterRoles = {
    cluster-view = kixlib'.rbac.mkClusterRole {
      metadata = {
        name = "cert-manager-cluster-view";
        labels = labels.all // {
          "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
        };
      };
      rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "clusterissuers" ]; verbs = [ "get" "list" "watch" ]; }
      ];
    };

    view = kixlib'.rbac.mkClusterRole {
      metadata = {
        name = "cert-manager-view";
        labels = labels.all // {
          "rbac.authorization.k8s.io/aggregate-to-view" = "true";
          "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
          "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
          "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
        };
      };
      rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" "certificaterequests" "issuers" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "challenges" "orders" ]; verbs = [ "get" "list" "watch" ]; }
      ];
    };

    edit = kixlib'.rbac.mkClusterRole {
      metadata = {
        name = "cert-manager-edit";
        labels = labels.all // {
          "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
          "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
        };
      };
      rules = [
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" "certificaterequests" "issuers" ]; verbs = [ "create" "delete" "deletecollection" "patch" "update" ]; }
        { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates/status" ]; verbs = [ "update" ]; }
        { apiGroups = [ "acme.cert-manager.io" ]; resources = [ "challenges" "orders" ]; verbs = [ "create" "delete" "deletecollection" "patch" "update" ]; }
      ];
    };
  };

  # Controller Roles — namespace-scoped for leader election and tokenrequest.
  # Leader election goes to cfg.leaderElection.namespace (default kube-system).
  controllerLeaderElectionRole = kixlib'.rbac.mkRole {
    metadata = {
      name = "cert-manager:leaderelection";
      namespace = cfg.leaderElection.namespace;
      labels = labels.all // { "app.kubernetes.io/component" = "controller"; };
    };
    rules = [
      { apiGroups = [ "coordination.k8s.io" ]; resources = [ "leases" ]; verbs = [ "get" "update" "patch" ];
        resourceNames = [ "cert-manager-controller" ]; }
      { apiGroups = [ "coordination.k8s.io" ]; resources = [ "leases" ]; verbs = [ "create" ]; }
    ];
  };

  controllerLeaderElectionRoleBinding = kixlib'.rbac.mkRoleBindingWith {
    role = controllerLeaderElectionRole;
    serviceAccount = controllerSa;
    metadata = {
      name = "cert-manager:leaderelection";
      namespace = cfg.leaderElection.namespace;
      labels = labels.all // { "app.kubernetes.io/component" = "controller"; };
    };
    subjects = [{
      kind = "ServiceAccount";
      name = "cert-manager";
      namespace = cfg.namespace;
    }];
  };

  # Tokenrequest Role — in the chart namespace, allows controller to create
  # tokens for its own ServiceAccount (used for self-signed issuers).
  controllerTokenrequestRole = kixlib'.rbac.mkRole {
    metadata = {
      name = "cert-manager-tokenrequest";
      labels = labels.all // { "app.kubernetes.io/component" = "controller"; };
    };
    rules = [
      { apiGroups = [ "" ]; resources = [ "serviceaccounts/token" ]; verbs = [ "create" ];
        resourceNames = [ "cert-manager" ]; }
    ];
  };

  controllerTokenrequestRoleBinding = kixlib'.rbac.mkRoleBindingWith {
    role = controllerTokenrequestRole;
    serviceAccount = controllerSa;
    metadata = {
      name = "cert-manager-tokenrequest";
      labels = labels.all // { "app.kubernetes.io/component" = "controller"; };
    };
    subjects = [{
      kind = "ServiceAccount";
      name = "cert-manager";
      namespace = cfg.namespace;
    }];
  };

  # ============================================================================
  # WEBHOOK COMPONENT
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
      initialDelaySeconds = 60;
      periodSeconds = 10;
      timeoutSeconds = 1;
      failureThreshold = 3;
      successThreshold = 1;
    };
    readinessProbe = {
      httpGet = { path = "/healthz"; port = "healthcheck"; scheme = "HTTP"; };
      initialDelaySeconds = 5;
      periodSeconds = 5;
      timeoutSeconds = 1;
      failureThreshold = 3;
      successThreshold = 1;
    };
  };

  webhookDeployment = kixlib'.workload.mkDeployment {
    metadata = { name = "cert-manager-webhook"; labels = webhookLabels.all; };
    replicas = cfg.webhook.replicaCount;
    selectorLabels = webhookLabels.selector;
    template = kixlib'.pod.mkPodTemplate {
      metadata = {
        labels = webhookLabels.all;
        annotations = prometheusAnnotations;
      };
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
      labels = webhookLabels.all;
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

  # Webhook RBAC
  webhookClusterRole = kixlib'.rbac.mkClusterRole {
    metadata = { name = "cert-manager-webhook:subjectaccessreviews"; labels = webhookLabels.all; };
    rules = [
      { apiGroups = [ "authorization.k8s.io" ]; resources = [ "subjectaccessreviews" ]; verbs = [ "create" ]; }
    ];
  };

  webhookClusterRoleBinding = kixlib'.rbac.mkClusterRoleBindingWith {
    clusterRole = webhookClusterRole;
    serviceAccount = webhookSa;
    metadata = { name = "cert-manager-webhook:subjectaccessreviews"; labels = webhookLabels.all; };
    subjects = [{
      kind = "ServiceAccount";
      name = "cert-manager-webhook";
      namespace = cfg.namespace;
    }];
  };

  # dynamic-serving Role — webhook manages its own CA secret for TLS.
  webhookDynamicServingRole = kixlib'.rbac.mkRole {
    metadata = {
      name = "cert-manager-webhook:dynamic-serving";
      labels = webhookLabels.all;
    };
    rules = [
      { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" "update" ];
        resourceNames = [ "cert-manager-webhook-ca" ]; }
      { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "create" ]; }
    ];
  };

  webhookDynamicServingRoleBinding = kixlib'.rbac.mkRoleBindingWith {
    role = webhookDynamicServingRole;
    serviceAccount = webhookSa;
    metadata = {
      name = "cert-manager-webhook:dynamic-serving";
      labels = webhookLabels.all;
    };
    subjects = [{
      kind = "ServiceAccount";
      name = "cert-manager-webhook";
      namespace = cfg.namespace;
    }];
  };

  # Webhook admission configurations.
  # caBundle is empty at deploy time — this is intentional, not an oversight.
  # The cainjector component watches for the cert-manager.io/inject-ca-from-secret
  # annotation on webhook configs and populates caBundle at runtime from the
  # referenced Secret. This is cert-manager's standard CA injection mechanism.
  # If cainjector is disabled, the webhook still works but the caBundle must be
  # populated by an external process (e.g., manual injection or another controller).
  mutatingWebhook = kixlib'.admission.mkMutatingWebhookConfiguration {
    metadata = {
      name = "cert-manager-webhook";
      labels = webhookLabels.all;
      annotations = {
        "cert-manager.io/inject-ca-from-secret" = "${cfg.namespace}/cert-manager-webhook-ca";
      };
    };
    webhooks = [{
      name = "webhook.cert-manager.io";
      rules = [{
        apiGroups = [ "cert-manager.io" ];
        apiVersions = [ "v1" ];
        operations = [ "CREATE" ];
        resources = [ "certificaterequests" ];
      }];
      admissionReviewVersions = [ "v1" ];
      matchPolicy = "Equivalent";
      timeoutSeconds = cfg.webhook.timeoutSeconds;
      failurePolicy = "Fail";
      sideEffects = "None";
      clientConfig = {
        service = {
          name = "cert-manager-webhook";
          namespace = cfg.namespace;
          path = "/mutate";
        };
      };
    }];
  };

  validatingWebhook = kixlib'.admission.mkValidatingWebhookConfiguration {
    metadata = {
      name = "cert-manager-webhook";
      labels = webhookLabels.all;
      annotations = {
        "cert-manager.io/inject-ca-from-secret" = "${cfg.namespace}/cert-manager-webhook-ca";
      };
    };
    webhooks = [{
      name = "webhook.cert-manager.io";
      namespaceSelector = {
        matchExpressions = [{
          key = "cert-manager.io/disable-validation";
          operator = "NotIn";
          values = [ "true" ];
        }];
      };
      rules = [{
        apiGroups = [ "cert-manager.io" "acme.cert-manager.io" ];
        apiVersions = [ "v1" ];
        operations = [ "CREATE" "UPDATE" ];
        resources = [ "*/*" ];
      }];
      admissionReviewVersions = [ "v1" ];
      matchPolicy = "Equivalent";
      timeoutSeconds = cfg.webhook.timeoutSeconds;
      failurePolicy = "Fail";
      sideEffects = "None";
      clientConfig = {
        service = {
          name = "cert-manager-webhook";
          namespace = cfg.namespace;
          path = "/validate";
        };
      };
    }];
  };

  # ============================================================================
  # CA INJECTOR COMPONENT (optional, behind cfg.cainjector.enabled)
  # ============================================================================

  cainjectorSa = kixlib'.rbac.mkServiceAccount {
    metadata = { name = "cert-manager-cainjector"; labels = cainjectorLabels.all; };
    automountServiceAccountToken = cfg.serviceAccount.automountServiceAccountToken;
  };

  cainjectorContainer = kixlib'.pod.mkContainer {
    name = "cert-manager-cainjector";
    image = kixlib.imageRef cfg.cainjector.image;
    imagePullPolicy = cfg.cainjector.image.pullPolicy;
    args = [
      "--v=${toString cfg.logLevel}"
      "--leader-election-namespace=${cfg.leaderElection.namespace}"
    ];
    ports = [
      { containerPort = 9402; protocol = "TCP"; name = "http-metrics"; }
    ];
    securityContext = containerSecCtx;
    resources = cfg.cainjector.resources;
    env = [ podNamespaceEnv ];
  };

  cainjectorDeployment = kixlib'.workload.mkDeployment {
    metadata = { name = "cert-manager-cainjector"; labels = cainjectorLabels.all; };
    replicas = cfg.cainjector.replicaCount;
    selectorLabels = cainjectorLabels.selector;
    template = kixlib'.pod.mkPodTemplate {
      metadata = {
        labels = cainjectorLabels.all;
        annotations = prometheusAnnotations;
      };
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
      labels = cainjectorLabels.all;
    };
    spec = {
      type = "ClusterIP";
      ports = [
        { port = 9402; protocol = "TCP"; name = "http-metrics"; }
      ];
      selector = cainjectorLabels.selector;
    };
  };

  # CA Injector RBAC
  cainjectorClusterRole = kixlib'.rbac.mkClusterRole {
    metadata = { name = "cert-manager-cainjector"; labels = cainjectorLabels.all; };
    rules = [
      { apiGroups = [ "cert-manager.io" ]; resources = [ "certificates" ]; verbs = [ "get" "list" "watch" ]; }
      { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" ]; }
      { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "get" "create" "update" "patch" ]; }
      { apiGroups = [ "admissionregistration.k8s.io" ]; resources = [ "validatingwebhookconfigurations" "mutatingwebhookconfigurations" ]; verbs = [ "get" "list" "watch" "update" "patch" ]; }
      { apiGroups = [ "apiregistration.k8s.io" ]; resources = [ "apiservices" ]; verbs = [ "get" "list" "watch" "update" "patch" ]; }
      { apiGroups = [ "apiextensions.k8s.io" ]; resources = [ "customresourcedefinitions" ]; verbs = [ "get" "list" "watch" "update" "patch" ]; }
    ];
  };

  cainjectorClusterRoleBinding = kixlib'.rbac.mkClusterRoleBindingWith {
    clusterRole = cainjectorClusterRole;
    serviceAccount = cainjectorSa;
    metadata = { name = "cert-manager-cainjector"; labels = cainjectorLabels.all; };
    subjects = [{
      kind = "ServiceAccount";
      name = "cert-manager-cainjector";
      namespace = cfg.namespace;
    }];
  };

  cainjectorLeaderElectionRole = kixlib'.rbac.mkRole {
    metadata = {
      name = "cert-manager-cainjector:leaderelection";
      namespace = cfg.leaderElection.namespace;
      labels = cainjectorLabels.all;
    };
    rules = [
      { apiGroups = [ "coordination.k8s.io" ]; resources = [ "leases" ]; verbs = [ "get" "update" "patch" ];
        resourceNames = [ "cert-manager-cainjector-leader-election" "cert-manager-cainjector-leader-election-core" ]; }
      { apiGroups = [ "coordination.k8s.io" ]; resources = [ "leases" ]; verbs = [ "create" ]; }
    ];
  };

  cainjectorLeaderElectionRoleBinding = kixlib'.rbac.mkRoleBindingWith {
    role = cainjectorLeaderElectionRole;
    serviceAccount = cainjectorSa;
    metadata = {
      name = "cert-manager-cainjector:leaderelection";
      namespace = cfg.leaderElection.namespace;
      labels = cainjectorLabels.all;
    };
    subjects = [{
      kind = "ServiceAccount";
      name = "cert-manager-cainjector";
      namespace = cfg.namespace;
    }];
  };

  # ============================================================================
  # STARTUP API CHECK (optional, behind cfg.startupapicheck.enabled)
  # ============================================================================
  # Post-install verification Job — checks that the cert-manager API (CRDs)
  # is available. In Helm this is a post-install hook; in kix it's a regular
  # Job that should be applied after the controller and CRDs are ready.

  startupapicheckSa = kixlib'.rbac.mkServiceAccount {
    metadata = { name = "cert-manager-startupapicheck"; labels = startupapicheckLabels.all; };
    automountServiceAccountToken = cfg.serviceAccount.automountServiceAccountToken;
  };

  startupapicheckJob = kixlib'.workload.mkJob {
    metadata = { name = "cert-manager-startupapicheck"; labels = startupapicheckLabels.all; };
    backoffLimit = 4;
    template = kixlib'.pod.mkPodTemplate {
      metadata = {
        labels = startupapicheckLabels.all;
      };
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

  startupapicheckRole = kixlib'.rbac.mkRole {
    metadata = {
      name = "cert-manager-startupapicheck:create-cert";
      labels = startupapicheckLabels.all;
    };
    rules = [
      { apiGroups = [ "cert-manager.io" ]; resources = [ "certificaterequests" ]; verbs = [ "create" ]; }
    ];
  };

  startupapicheckRoleBinding = kixlib'.rbac.mkRoleBindingWith {
    role = startupapicheckRole;
    serviceAccount = startupapicheckSa;
    metadata = {
      name = "cert-manager-startupapicheck:create-cert";
      labels = startupapicheckLabels.all;
    };
    subjects = [{
      kind = "ServiceAccount";
      name = "cert-manager-startupapicheck";
      namespace = cfg.namespace;
    }];
  };

  # --- Declarative manifest list ---
  # All resources in a flat list with enable conditions. This replaces the
  # chained `// lib.optionalAttrs` pattern for clarity and maintainability.
  # Dynamic RBAC resources (controllerClusterRoles, controllerClusterRoleBindings,
  # aggregatedClusterRoles) are expanded programmatically via lib.mapAttrsToList.
  manifestList =
    # Controller (always present when chart is enabled)
    [
      { name = "cert-manager-sa"; resource = controllerSa; enable = cfg.serviceAccount.create; }
      { name = "cert-manager-deployment"; resource = controllerDeployment; enable = true; }
      { name = "cert-manager-service"; resource = controllerService; enable = true; }
    ]
    # Controller RBAC — dynamically generated from the ClusterRole/ClusterRoleBinding attrsets
    ++ lib.mapAttrsToList (n: role:
      { name = "cert-manager-clusterrole-${n}"; resource = role; enable = cfg.rbac.create; }
    ) controllerClusterRoles
    ++ lib.mapAttrsToList (n: binding:
      { name = "cert-manager-clusterrolebinding-${n}"; resource = binding; enable = cfg.rbac.create; }
    ) controllerClusterRoleBindings
    ++ lib.mapAttrsToList (n: role:
      { name = "cert-manager-clusterrole-${n}"; resource = role; enable = cfg.rbac.create && cfg.rbac.aggregateClusterRoles; }
    ) aggregatedClusterRoles
    ++ [
      # Controller namespace-scoped Roles (leader election + tokenrequest)
      { name = "cert-manager-role-leaderelection"; resource = controllerLeaderElectionRole; enable = cfg.rbac.create; }
      { name = "cert-manager-rolebinding-leaderelection"; resource = controllerLeaderElectionRoleBinding; enable = cfg.rbac.create; }
      { name = "cert-manager-role-tokenrequest"; resource = controllerTokenrequestRole; enable = cfg.rbac.create; }
      { name = "cert-manager-rolebinding-tokenrequest"; resource = controllerTokenrequestRoleBinding; enable = cfg.rbac.create; }
      # Webhook (always present when chart is enabled)
      { name = "cert-manager-webhook-sa"; resource = webhookSa; enable = cfg.serviceAccount.create; }
      { name = "cert-manager-webhook-deployment"; resource = webhookDeployment; enable = true; }
      { name = "cert-manager-webhook-service"; resource = webhookService; enable = true; }
      { name = "cert-manager-webhook-mutatingwebhookconfig"; resource = mutatingWebhook; enable = true; }
      { name = "cert-manager-webhook-validatingwebhookconfig"; resource = validatingWebhook; enable = true; }
      { name = "cert-manager-webhook-clusterrole"; resource = webhookClusterRole; enable = cfg.rbac.create; }
      { name = "cert-manager-webhook-clusterrolebinding"; resource = webhookClusterRoleBinding; enable = cfg.rbac.create; }
      { name = "cert-manager-webhook-role-dynamic-serving"; resource = webhookDynamicServingRole; enable = cfg.rbac.create; }
      { name = "cert-manager-webhook-rolebinding-dynamic-serving"; resource = webhookDynamicServingRoleBinding; enable = cfg.rbac.create; }
      # CA Injector (optional, behind cfg.cainjector.enabled)
      { name = "cert-manager-cainjector-sa"; resource = cainjectorSa; enable = cfg.cainjector.enabled && cfg.serviceAccount.create; }
      { name = "cert-manager-cainjector-deployment"; resource = cainjectorDeployment; enable = cfg.cainjector.enabled; }
      { name = "cert-manager-cainjector-service"; resource = cainjectorService; enable = cfg.cainjector.enabled; }
      { name = "cert-manager-cainjector-clusterrole"; resource = cainjectorClusterRole; enable = cfg.cainjector.enabled && cfg.rbac.create; }
      { name = "cert-manager-cainjector-clusterrolebinding"; resource = cainjectorClusterRoleBinding; enable = cfg.cainjector.enabled && cfg.rbac.create; }
      { name = "cert-manager-cainjector-role-leaderelection"; resource = cainjectorLeaderElectionRole; enable = cfg.cainjector.enabled && cfg.rbac.create; }
      { name = "cert-manager-cainjector-rolebinding-leaderelection"; resource = cainjectorLeaderElectionRoleBinding; enable = cfg.cainjector.enabled && cfg.rbac.create; }
      # Startup API Check (optional, behind cfg.startupapicheck.enabled)
      { name = "cert-manager-startupapicheck-sa"; resource = startupapicheckSa; enable = cfg.startupapicheck.enabled && cfg.serviceAccount.create; }
      { name = "cert-manager-startupapicheck-job"; resource = startupapicheckJob; enable = cfg.startupapicheck.enabled; }
      { name = "cert-manager-startupapicheck-role"; resource = startupapicheckRole; enable = cfg.startupapicheck.enabled && cfg.rbac.create; }
      { name = "cert-manager-startupapicheck-rolebinding"; resource = startupapicheckRoleBinding; enable = cfg.startupapicheck.enabled && cfg.rbac.create; }
    ];

in
{
  config = lib.mkIf cfg.enable {
    # Level 1: consume cluster domain default.
    services.cert-manager.clusterDomain = lib.mkDefault config.cluster.domain;

    # Level 2: service registry — expose webhook and metrics endpoints.
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

    # Level 3: monitoring targets — controller, webhook, and cainjector all expose
    # metrics on port 9402. These are declared so the cross-cutting monitoring
    # module can create ServiceMonitors for them.
    monitoring.targets.cert-manager = {
      serviceName = "cert-manager";
      namespace = cfg.namespace;
      portName = "tcp-prometheus-servicemonitor";
      selector = labels.selector;
    };
    monitoring.targets.cert-manager-webhook = {
      serviceName = "cert-manager-webhook";
      namespace = cfg.namespace;
      portName = "metrics";
      selector = webhookLabels.selector;
    };
    monitoring.targets.cert-manager-cainjector = lib.mkIf cfg.cainjector.enabled {
      serviceName = "cert-manager-cainjector";
      namespace = cfg.namespace;
      portName = "http-metrics";
      selector = cainjectorLabels.selector;
    };

    # Build manifests from the declarative list — filter by enable, then serialize.
    manifests = lib.listToAttrs (
      map (r: lib.nameValuePair r.name (kixlib'.mkManifest r.resource))
      (builtins.filter (r: r.enable) manifestList)
    );
  };
}
