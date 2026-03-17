# cert-manager package — v2.
#
# Migrated from pkgs-fp/cert-manager/ (v1 fixpoint pattern).
# Source Helm chart: jetstack/cert-manager (v1.19.4)
#
# cert-manager has 4 components:
#   - controller  — the core certificate lifecycle manager
#   - webhook     — admission webhooks for CRD validation/mutation
#   - cainjector  — injects CA bundles into webhook/apiservice/CRD annotations
#   - startupapicheck — post-install Job verifying the API is healthy
#
# The `main` resource is the controller Service. Deploying the closure
# includes all 4 components' Deployments, RBAC, webhook configs, and
# everything else needed to make cert-manager work.
#
# RBAC is extensive: 8 ClusterRoles for the controller alone, plus aggregated
# roles, webhook RBAC, cainjector RBAC, and startupapicheck RBAC. Each role
# is modeled as a separate resource so overrideParts can swap individual roles.

{ scope, config, lib }:

let
  cfg = scope.defaults config {
    clusterDomain = "cluster.local";

    # Controller
    image = {
      repository = "quay.io/jetstack/cert-manager-controller";
      tag = "v1.19.4";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 1;
    logLevel = 2;
    maxConcurrentChallenges = 60;
    acmeSolverImage = {
      repository = "quay.io/jetstack/cert-manager-acmesolver";
      tag = "v1.19.4";
      pullPolicy = "IfNotPresent";
    };
    resources = { };
    leaderElection = {
      namespace = "kube-system";
    };

    # Service account
    serviceAccount = {
      create = true;
      automountServiceAccountToken = true;
    };

    # RBAC
    rbac = {
      create = true;
      aggregateClusterRoles = true;
    };

    # Security contexts
    securityContext = {
      runAsNonRoot = true;
      seccompProfile.type = "RuntimeDefault";
    };
    containerSecurityContext = {
      allowPrivilegeEscalation = false;
      capabilities = {
        drop = [ "ALL" ];
      };
      readOnlyRootFilesystem = true;
    };

    # Prometheus
    prometheus = {
      enabled = true;
    };

    # Webhook
    webhook = {
      image = {
        repository = "quay.io/jetstack/cert-manager-webhook";
        tag = "v1.19.4";
        pullPolicy = "IfNotPresent";
      };
      replicaCount = 1;
      resources = { };
      securePort = 10250;
      timeoutSeconds = 30;
    };

    # CA Injector
    cainjector = {
      enabled = true;
      image = {
        repository = "quay.io/jetstack/cert-manager-cainjector";
        tag = "v1.19.4";
        pullPolicy = "IfNotPresent";
      };
      replicaCount = 1;
      resources = { };
    };

    # Startup API Check
    startupapicheck = {
      enabled = true;
      image = {
        repository = "quay.io/jetstack/cert-manager-startupapicheck";
        tag = "v1.19.4";
        pullPolicy = "IfNotPresent";
      };
      resources = { };
    };
  };

  # --- Derived values ---

  controllerImageRef = "${cfg.image.repository}:${cfg.image.tag}";
  webhookImageRef = "${cfg.webhook.image.repository}:${cfg.webhook.image.tag}";
  cainjectorImageRef = "${cfg.cainjector.image.repository}:${cfg.cainjector.image.tag}";
  startupapicheckImageRef = "${cfg.startupapicheck.image.repository}:${cfg.startupapicheck.image.tag}";
  acmeSolverImageRef = "${cfg.acmeSolverImage.repository}:${cfg.acmeSolverImage.tag}";

  # --- Labels ---
  # Per-component labels following cert-manager Helm chart conventions.
  # The controller uses "cert-manager" as app name; all others use
  # "cert-manager-<component>".

  mkComponentLabels = component: {
    "app.kubernetes.io/name" =
      if component == "controller" then "cert-manager" else "cert-manager-${component}";
    "app.kubernetes.io/instance" = scope.instanceName;
    "app.kubernetes.io/component" = component;
    "app.kubernetes.io/managed-by" = "kix";
  };

  controllerLabels = mkComponentLabels "controller";
  webhookLabels = mkComponentLabels "webhook";
  cainjectorLabels = mkComponentLabels "cainjector";
  startupapicheckLabels = mkComponentLabels "startupapicheck";

  # Selector labels (subset used for matchLabels)
  mkSelectorLabels = component: {
    "app.kubernetes.io/name" =
      if component == "controller" then "cert-manager" else "cert-manager-${component}";
    "app.kubernetes.io/instance" = scope.instanceName;
    "app.kubernetes.io/component" = component;
  };

  controllerSelectorLabels = mkSelectorLabels "controller";
  webhookSelectorLabels = mkSelectorLabels "webhook";
  cainjectorSelectorLabels = mkSelectorLabels "cainjector";

  # --- Security contexts ---

  podSecurityContext = cfg.securityContext;
  containerSecCtx = cfg.containerSecurityContext;

  # --- Shared values ---

  podNamespaceEnv = {
    name = "POD_NAMESPACE";
    valueFrom.fieldRef.fieldPath = "metadata.namespace";
  };

  nodeSelector = {
    "kubernetes.io/os" = "linux";
  };

  prometheusAnnotations = lib.optionalAttrs cfg.prometheus.enabled {
    "prometheus.io/path" = "/metrics";
    "prometheus.io/scrape" = "true";
    "prometheus.io/port" = "9402";
  };

  # --- Container specs ---

  controllerContainer = {
    name = "cert-manager-controller";
    image = controllerImageRef;
    imagePullPolicy = cfg.image.pullPolicy;
    args = [
      "--v=${toString cfg.logLevel}"
      "--cluster-resource-namespace=$(POD_NAMESPACE)"
      "--leader-election-namespace=${cfg.leaderElection.namespace}"
      "--acme-http01-solver-image=${acmeSolverImageRef}"
      "--max-concurrent-challenges=${toString cfg.maxConcurrentChallenges}"
    ];
    ports = [
      {
        containerPort = 9402;
        protocol = "TCP";
        name = "http-metrics";
      }
      {
        containerPort = 9403;
        protocol = "TCP";
        name = "http-healthz";
      }
    ];
    securityContext = containerSecCtx;
    env = [ podNamespaceEnv ];
    livenessProbe = {
      httpGet = {
        path = "/livez";
        port = "http-healthz";
        scheme = "HTTP";
      };
      initialDelaySeconds = 10;
      periodSeconds = 10;
      timeoutSeconds = 15;
      failureThreshold = 8;
      successThreshold = 1;
    };
  }
  // lib.optionalAttrs (cfg.resources != { }) { inherit (cfg) resources; };

  webhookContainer = {
    name = "cert-manager-webhook";
    image = webhookImageRef;
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
      {
        containerPort = cfg.webhook.securePort;
        protocol = "TCP";
        name = "https";
      }
      {
        containerPort = 6080;
        protocol = "TCP";
        name = "healthcheck";
      }
      {
        containerPort = 9402;
        protocol = "TCP";
        name = "http-metrics";
      }
    ];
    securityContext = containerSecCtx;
    env = [ podNamespaceEnv ];
    livenessProbe = {
      httpGet = {
        path = "/livez";
        port = "healthcheck";
        scheme = "HTTP";
      };
      initialDelaySeconds = 60;
      periodSeconds = 10;
      timeoutSeconds = 1;
      failureThreshold = 3;
      successThreshold = 1;
    };
    readinessProbe = {
      httpGet = {
        path = "/healthz";
        port = "healthcheck";
        scheme = "HTTP";
      };
      initialDelaySeconds = 5;
      periodSeconds = 5;
      timeoutSeconds = 1;
      failureThreshold = 3;
      successThreshold = 1;
    };
  }
  // lib.optionalAttrs (cfg.webhook.resources != { }) {
    resources = cfg.webhook.resources;
  };

  cainjectorContainer = {
    name = "cert-manager-cainjector";
    image = cainjectorImageRef;
    imagePullPolicy = cfg.cainjector.image.pullPolicy;
    args = [
      "--v=${toString cfg.logLevel}"
      "--leader-election-namespace=${cfg.leaderElection.namespace}"
    ];
    ports = [
      {
        containerPort = 9402;
        protocol = "TCP";
        name = "http-metrics";
      }
    ];
    securityContext = containerSecCtx;
    env = [ podNamespaceEnv ];
  }
  // lib.optionalAttrs (cfg.cainjector.resources != { }) {
    resources = cfg.cainjector.resources;
  };

  startupapicheckContainer = {
    name = "cert-manager-startupapicheck";
    image = startupapicheckImageRef;
    imagePullPolicy = cfg.startupapicheck.image.pullPolicy;
    args = [
      "check"
      "api"
      "--wait=1m"
      "-v"
    ];
    securityContext = containerSecCtx;
    env = [ podNamespaceEnv ];
  }
  // lib.optionalAttrs (cfg.startupapicheck.resources != { }) {
    resources = cfg.startupapicheck.resources;
  };

in self:
let
  # SA name helpers — must be inside the `self:` scope since they
  # reference self.controllerSa etc. via interpolation.
  controllerSaName = if cfg.serviceAccount.create then "${self.controllerSa}" else "default";
  webhookSaName = if cfg.serviceAccount.create then "${self.webhookSa}" else "default";
  cainjectorSaName = if cfg.serviceAccount.create then "${self.cainjectorSa}" else "default";
  startupapicheckSaName = if cfg.serviceAccount.create then "${self.startupapicheckSa}" else "default";
in {

  # ====================================================================
  # CONTROLLER RBAC
  # ====================================================================

  # --- ClusterRoles ---

  controllerClusterRoleIssuers = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-cert-manager-controller-issuers";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "issuers"
          "issuers/status"
        ];
        verbs = [
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [ "issuers" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "delete"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
    ];
  };

  controllerClusterRoleClusterissuers = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-cert-manager-controller-clusterissuers";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "clusterissuers"
          "clusterissuers/status"
        ];
        verbs = [
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [ "clusterissuers" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "delete"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
    ];
  };

  controllerClusterRoleCertificates = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-cert-manager-controller-certificates";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates"
          "certificates/status"
          "certificaterequests"
          "certificaterequests/status"
        ];
        verbs = [
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates"
          "certificaterequests"
          "clusterissuers"
          "issuers"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates/finalizers"
          "certificaterequests/finalizers"
        ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [ "orders" ];
        verbs = [
          "create"
          "delete"
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "delete"
          "patch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
    ];
  };

  controllerClusterRoleOrders = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-cert-manager-controller-orders";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [
          "orders"
          "orders/status"
        ];
        verbs = [
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [
          "orders"
          "challenges"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "clusterissuers"
          "issuers"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [ "challenges" ];
        verbs = [
          "create"
          "delete"
        ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [ "orders/finalizers" ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
    ];
  };

  controllerClusterRoleChallenges = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-cert-manager-controller-challenges";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [
          "challenges"
          "challenges/status"
        ];
        verbs = [
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [ "challenges" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "issuers"
          "clusterissuers"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [
          "pods"
          "services"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "delete"
        ];
      }
      {
        apiGroups = [ "networking.k8s.io" ];
        resources = [ "ingresses" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "delete"
          "update"
        ];
      }
      {
        apiGroups = [ "gateway.networking.k8s.io" ];
        resources = [ "httproutes" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "delete"
          "update"
        ];
      }
      {
        apiGroups = [ "route.openshift.io" ];
        resources = [ "routes/custom-host" ];
        verbs = [ "create" ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [ "challenges/finalizers" ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
    ];
  };

  controllerClusterRoleIngressShim = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-cert-manager-controller-ingress-shim";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates"
          "certificaterequests"
        ];
        verbs = [
          "create"
          "update"
          "delete"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates"
          "certificaterequests"
          "issuers"
          "clusterissuers"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "networking.k8s.io" ];
        resources = [ "ingresses" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "networking.k8s.io" ];
        resources = [ "ingresses/finalizers" ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "gateway.networking.k8s.io" ];
        resources = [
          "gateways"
          "httproutes"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "gateway.networking.k8s.io" ];
        resources = [
          "gateways/finalizers"
          "httproutes/finalizers"
        ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
    ];
  };

  controllerClusterRoleApprove = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-cert-manager-controller-approve:cert-manager-io";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [ "signers" ];
        verbs = [ "approve" ];
        resourceNames = [
          "issuers.cert-manager.io/*"
          "clusterissuers.cert-manager.io/*"
        ];
      }
    ];
  };

  controllerClusterRoleCertificatesigningrequests = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-cert-manager-controller-certificatesigningrequests";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "certificates.k8s.io" ];
        resources = [ "certificatesigningrequests" ];
        verbs = [
          "get"
          "list"
          "watch"
          "update"
        ];
      }
      {
        apiGroups = [ "certificates.k8s.io" ];
        resources = [ "certificatesigningrequests/status" ];
        verbs = [
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "certificates.k8s.io" ];
        resources = [ "signers" ];
        verbs = [ "sign" ];
        resourceNames = [
          "issuers.cert-manager.io/*"
          "clusterissuers.cert-manager.io/*"
        ];
      }
      {
        apiGroups = [ "authorization.k8s.io" ];
        resources = [ "subjectaccessreviews" ];
        verbs = [ "create" ];
      }
    ];
  };

  # --- Controller ClusterRoleBindings (one per ClusterRole) ---

  controllerBindingIssuers = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-cert-manager-controller-issuers";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerClusterRoleIssuers}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = controllerSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  controllerBindingClusterissuers = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-cert-manager-controller-clusterissuers";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerClusterRoleClusterissuers}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = controllerSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  controllerBindingCertificates = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-cert-manager-controller-certificates";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerClusterRoleCertificates}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = controllerSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  controllerBindingOrders = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-cert-manager-controller-orders";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerClusterRoleOrders}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = controllerSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  controllerBindingChallenges = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-cert-manager-controller-challenges";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerClusterRoleChallenges}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = controllerSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  controllerBindingIngressShim = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-cert-manager-controller-ingress-shim";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerClusterRoleIngressShim}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = controllerSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  controllerBindingApprove = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-cert-manager-controller-approve:cert-manager-io";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerClusterRoleApprove}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = controllerSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  controllerBindingCertificatesigningrequests = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-cert-manager-controller-certificatesigningrequests";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerClusterRoleCertificatesigningrequests}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = controllerSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  # --- Aggregated ClusterRoles (no bindings, just roles with aggregation labels) ---

  aggregatedClusterRoleClusterView = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-cert-manager-cluster-view";
    labels = controllerLabels // {
      "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
    };
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [ "clusterissuers" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
    ];
  };

  aggregatedClusterRoleView = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-cert-manager-view";
    labels = controllerLabels // {
      "rbac.authorization.k8s.io/aggregate-to-view" = "true";
      "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
      "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
      "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
    };
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates"
          "certificaterequests"
          "issuers"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [
          "challenges"
          "orders"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
    ];
  };

  aggregatedClusterRoleEdit = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-cert-manager-edit";
    labels = controllerLabels // {
      "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
      "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
    };
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates"
          "certificaterequests"
          "issuers"
        ];
        verbs = [
          "create"
          "delete"
          "deletecollection"
          "patch"
          "update"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [ "certificates/status" ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [
          "challenges"
          "orders"
        ];
        verbs = [
          "create"
          "delete"
          "deletecollection"
          "patch"
          "update"
        ];
      }
    ];
  };

  # --- Controller namespaced Roles + RoleBindings ---
  # Note: In v1 these were in leaderElection.namespace (kube-system).
  # In v2, scope.mkResource auto-injects the package namespace.

  controllerRoleLeaderelection = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${scope.instanceName}-cert-manager:leaderelection";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        verbs = [
          "get"
          "update"
          "patch"
        ];
        resourceNames = [ "cert-manager-controller" ];
      }
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        verbs = [ "create" ];
      }
    ];
  };

  controllerRoleBindingLeaderelection = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${scope.instanceName}-cert-manager:leaderelection";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.controllerRoleLeaderelection}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = controllerSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  controllerRoleTokenrequest = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${scope.instanceName}-cert-manager-tokenrequest";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "serviceaccounts/token" ];
        verbs = [ "create" ];
        resourceNames = [ "cert-manager" ];
      }
    ];
  };

  controllerRoleBindingTokenrequest = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${scope.instanceName}-cert-manager-tokenrequest";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.controllerRoleTokenrequest}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = controllerSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  # ── Controller ServiceAccount ─────────────────────────────────────

  controllerSa = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-cert-manager";
    labels = controllerLabels;
    extra = lib.optionalAttrs cfg.serviceAccount.automountServiceAccountToken {
      automountServiceAccountToken = true;
    };
  };

  # ── Controller Deployment ──────────────────────────────────────────

  controllerDeployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-cert-manager";
    labels = controllerLabels // {
      "app.kubernetes.io/version" = cfg.image.tag;
    };
    requires = lib.optional cfg.serviceAccount.create self.controllerSa;
    spec = {
      replicas = cfg.replicaCount;
      selector.matchLabels = controllerSelectorLabels;
      template = {
        metadata = {
          labels = controllerLabels;
          annotations = prometheusAnnotations;
        };
        spec = {
          serviceAccountName = controllerSaName;
          enableServiceLinks = false;
          securityContext = podSecurityContext;
          inherit nodeSelector;
          containers = [ controllerContainer ];
        };
      };
    };
  };

  # ── Controller Service ─────────────────────────────────────────────

  controllerService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${scope.instanceName}-cert-manager";
    labels = controllerLabels;
    annotations = prometheusAnnotations;
    outputs = {
      metricsPort = 9402;
    };
    spec = {
      selector = controllerSelectorLabels;
      ports = [
        {
          port = 9402;
          protocol = "TCP";
          targetPort = "http-metrics";
          name = "tcp-prometheus-servicemonitor";
        }
      ];
    };
  };

  # ====================================================================
  # WEBHOOK RBAC
  # ====================================================================

  webhookClusterRoleSubjectaccessreviews = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-cert-manager-webhook:subjectaccessreviews";
    labels = webhookLabels;
    extra.rules = [
      {
        apiGroups = [ "authorization.k8s.io" ];
        resources = [ "subjectaccessreviews" ];
        verbs = [ "create" ];
      }
    ];
  };

  webhookBindingSubjectaccessreviews = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-cert-manager-webhook:subjectaccessreviews";
    labels = webhookLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.webhookClusterRoleSubjectaccessreviews}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = webhookSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  webhookRoleDynamicServing = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${scope.instanceName}-cert-manager-webhook:dynamic-serving";
    labels = webhookLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
          "update"
        ];
        resourceNames = [ "cert-manager-webhook-ca" ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [ "create" ];
      }
    ];
  };

  webhookRoleBindingDynamicServing = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${scope.instanceName}-cert-manager-webhook:dynamic-serving";
    labels = webhookLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.webhookRoleDynamicServing}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = webhookSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  # ── Webhook ServiceAccount ─────────────────────────────────────────

  webhookSa = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-cert-manager-webhook";
    labels = webhookLabels;
    extra = lib.optionalAttrs cfg.serviceAccount.automountServiceAccountToken {
      automountServiceAccountToken = true;
    };
  };

  # ── Webhook Deployment ─────────────────────────────────────────────

  webhookDeployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-cert-manager-webhook";
    labels = webhookLabels // {
      "app.kubernetes.io/version" = cfg.webhook.image.tag;
    };
    requires = lib.optional cfg.serviceAccount.create self.webhookSa;
    spec = {
      replicas = cfg.webhook.replicaCount;
      selector.matchLabels = webhookSelectorLabels;
      template = {
        metadata = {
          labels = webhookLabels;
          annotations = prometheusAnnotations;
        };
        spec = {
          serviceAccountName = webhookSaName;
          enableServiceLinks = false;
          securityContext = podSecurityContext;
          inherit nodeSelector;
          containers = [ webhookContainer ];
        };
      };
    };
  };

  # ── Webhook Service ────────────────────────────────────────────────

  webhookService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${scope.instanceName}-cert-manager-webhook";
    labels = webhookLabels;
    annotations = prometheusAnnotations;
    outputs = {
      httpsPort = 443;
      metricsPort = 9402;
    };
    requires = [ self.webhookDeployment ];
    spec = {
      selector = webhookSelectorLabels;
      ports = [
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
    };
  };

  # ── Webhook Admission Configurations ───────────────────────────────

  mutatingWebhook = scope.mkClusterResource {
    apiVersion = "admissionregistration.k8s.io/v1";
    kind = "MutatingWebhookConfiguration";
    name = "${scope.instanceName}-cert-manager-webhook";
    labels = webhookLabels;
    annotations = {
      "cert-manager.io/inject-ca-from-secret" = "${scope.namespaceName}/cert-manager-webhook-ca";
    };
    extra.webhooks = [
      {
        name = "webhook.cert-manager.io";
        rules = [
          {
            apiGroups = [ "cert-manager.io" ];
            apiVersions = [ "v1" ];
            operations = [ "CREATE" ];
            resources = [ "certificaterequests" ];
          }
        ];
        admissionReviewVersions = [ "v1" ];
        matchPolicy = "Equivalent";
        timeoutSeconds = cfg.webhook.timeoutSeconds;
        failurePolicy = "Fail";
        sideEffects = "None";
        clientConfig.service = {
          name = "${self.webhookService}";
          namespace = scope.namespaceName;
          path = "/mutate";
        };
      }
    ];
  };

  validatingWebhook = scope.mkClusterResource {
    apiVersion = "admissionregistration.k8s.io/v1";
    kind = "ValidatingWebhookConfiguration";
    name = "${scope.instanceName}-cert-manager-webhook";
    labels = webhookLabels;
    annotations = {
      "cert-manager.io/inject-ca-from-secret" = "${scope.namespaceName}/cert-manager-webhook-ca";
    };
    extra.webhooks = [
      {
        name = "webhook.cert-manager.io";
        namespaceSelector.matchExpressions = [
          {
            key = "cert-manager.io/disable-validation";
            operator = "NotIn";
            values = [ "true" ];
          }
        ];
        rules = [
          {
            apiGroups = [
              "cert-manager.io"
              "acme.cert-manager.io"
            ];
            apiVersions = [ "v1" ];
            operations = [
              "CREATE"
              "UPDATE"
            ];
            resources = [ "*/*" ];
          }
        ];
        admissionReviewVersions = [ "v1" ];
        matchPolicy = "Equivalent";
        timeoutSeconds = cfg.webhook.timeoutSeconds;
        failurePolicy = "Fail";
        sideEffects = "None";
        clientConfig.service = {
          name = "${self.webhookService}";
          namespace = scope.namespaceName;
          path = "/validate";
        };
      }
    ];
  };

  # ====================================================================
  # CA INJECTOR RBAC
  # ====================================================================

  cainjectorClusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-cert-manager-cainjector";
    labels = cainjectorLabels;
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [ "certificates" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "get"
          "create"
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "admissionregistration.k8s.io" ];
        resources = [
          "validatingwebhookconfigurations"
          "mutatingwebhookconfigurations"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "apiregistration.k8s.io" ];
        resources = [ "apiservices" ];
        verbs = [
          "get"
          "list"
          "watch"
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "apiextensions.k8s.io" ];
        resources = [ "customresourcedefinitions" ];
        verbs = [
          "get"
          "list"
          "watch"
          "update"
          "patch"
        ];
      }
    ];
  };

  cainjectorBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-cert-manager-cainjector";
    labels = cainjectorLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.cainjectorClusterRole}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = cainjectorSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  cainjectorRoleLeaderelection = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${scope.instanceName}-cert-manager-cainjector:leaderelection";
    labels = cainjectorLabels;
    extra.rules = [
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        verbs = [
          "get"
          "update"
          "patch"
        ];
        resourceNames = [
          "cert-manager-cainjector-leader-election"
          "cert-manager-cainjector-leader-election-core"
        ];
      }
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        verbs = [ "create" ];
      }
    ];
  };

  cainjectorRoleBindingLeaderelection = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${scope.instanceName}-cert-manager-cainjector:leaderelection";
    labels = cainjectorLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.cainjectorRoleLeaderelection}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = cainjectorSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  # ── CA Injector ServiceAccount ─────────────────────────────────────

  cainjectorSa = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-cert-manager-cainjector";
    labels = cainjectorLabels;
    extra = lib.optionalAttrs cfg.serviceAccount.automountServiceAccountToken {
      automountServiceAccountToken = true;
    };
  };

  # ── CA Injector Deployment ─────────────────────────────────────────

  cainjectorDeployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-cert-manager-cainjector";
    labels = cainjectorLabels // {
      "app.kubernetes.io/version" = cfg.cainjector.image.tag;
    };
    requires = lib.optional cfg.serviceAccount.create self.cainjectorSa;
    spec = {
      replicas = cfg.cainjector.replicaCount;
      selector.matchLabels = cainjectorSelectorLabels;
      template = {
        metadata = {
          labels = cainjectorLabels;
          annotations = prometheusAnnotations;
        };
        spec = {
          serviceAccountName = cainjectorSaName;
          enableServiceLinks = false;
          securityContext = podSecurityContext;
          inherit nodeSelector;
          containers = [ cainjectorContainer ];
        };
      };
    };
  };

  # ── CA Injector Service ────────────────────────────────────────────

  cainjectorService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${scope.instanceName}-cert-manager-cainjector";
    labels = cainjectorLabels;
    annotations = prometheusAnnotations;
    requires = [ self.cainjectorDeployment ];
    spec = {
      selector = cainjectorSelectorLabels;
      ports = [
        {
          port = 9402;
          protocol = "TCP";
          name = "http-metrics";
        }
      ];
    };
  };

  # ====================================================================
  # STARTUP API CHECK RBAC
  # ====================================================================

  startupapicheckRoleCreateCert = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${scope.instanceName}-cert-manager-startupapicheck:create-cert";
    labels = startupapicheckLabels;
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [ "certificaterequests" ];
        verbs = [ "create" ];
      }
    ];
  };

  startupapicheckRoleBindingCreateCert = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${scope.instanceName}-cert-manager-startupapicheck:create-cert";
    labels = startupapicheckLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.startupapicheckRoleCreateCert}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = startupapicheckSaName;
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  # ── Startup API Check ServiceAccount ───────────────────────────────

  startupapicheckSa = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-cert-manager-startupapicheck";
    labels = startupapicheckLabels;
    extra = lib.optionalAttrs cfg.serviceAccount.automountServiceAccountToken {
      automountServiceAccountToken = true;
    };
  };

  # ── Startup API Check Job ──────────────────────────────────────────

  startupapicheckJob = scope.mkResource {
    apiVersion = "batch/v1";
    kind = "Job";
    name = "${scope.instanceName}-cert-manager-startupapicheck";
    labels = startupapicheckLabels;
    requires = lib.optional cfg.serviceAccount.create self.startupapicheckSa;
    spec = {
      backoffLimit = 4;
      template = {
        metadata = {
          labels = startupapicheckLabels;
        };
        spec = {
          restartPolicy = "OnFailure";
          serviceAccountName = startupapicheckSaName;
          enableServiceLinks = false;
          securityContext = podSecurityContext;
          inherit nodeSelector;
          containers = [ startupapicheckContainer ];
        };
      };
    };
  };

  # ====================================================================
  # MAIN — the public interface
  # ====================================================================
  #
  # From outside, cert-manager IS the controller Service. But deploying it
  # requires the webhook (needed for CRD validation), optionally the
  # cainjector and startupapicheck.

  main = {
    resource = self.controllerService;
    requires =
      [
        self.controllerDeployment
        self.webhookService
        self.mutatingWebhook
        self.validatingWebhook
      ]
      ++ lib.optional cfg.cainjector.enabled self.cainjectorDeployment
      ++ lib.optional cfg.startupapicheck.enabled self.startupapicheckJob;
  };
}
