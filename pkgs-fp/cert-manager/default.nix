# cert-manager package — fixpoint pattern.
#
# Migrated from pkgs/cert-manager/ (module-system version).
# Source Helm chart: jetstack/cert-manager (v1.19.4)
#
# This package defines cert-manager as a self-referential set of K8s resources
# using the inner fixpoint (lib.fix). Resources reference each other via
# `self.*` and the tree walker tracks dependencies automatically.
#
# cert-manager has 4 components:
#   - controller  — the core certificate lifecycle manager
#   - webhook     — admission webhooks for CRD validation/mutation
#   - cainjector  — injects CA bundles into webhook/apiservice/CRD annotations
#   - startupapicheck — post-install Job verifying the API is healthy
#
# The `main` resource is the controller Service. Deploying `main.closure`
# includes all 4 components' Deployments, RBAC, webhook configs, and
# everything else needed to make cert-manager work.
#
# RBAC is extensive: 8 ClusterRoles for the controller alone, plus aggregated
# roles, webhook RBAC, cainjector RBAC, and startupapicheck RBAC. Each role
# is modeled as a separate resource so overrideParts can swap individual roles.

{ k8s, lib }:

k8s.mkPackage
  (
    {
      # ── Package arguments (replaces options.nix) ───────────────────────
      namespace ? "cert-manager",
      instance ? "release-name",
      clusterLabels ? { },
      clusterDomain ? "cluster.local",

      # Controller
      image ? {
        repository = "quay.io/jetstack/cert-manager-controller";
        tag = "v1.19.4";
        pullPolicy = "IfNotPresent";
      },
      replicaCount ? 1,
      logLevel ? 2,
      maxConcurrentChallenges ? 60,
      acmeSolverImage ? {
        repository = "quay.io/jetstack/cert-manager-acmesolver";
        tag = "v1.19.4";
        pullPolicy = "IfNotPresent";
      },
      resources ? { },
      leaderElection ? { namespace = "kube-system"; },

      # Service account
      serviceAccount ? {
        create = true;
        automountServiceAccountToken = true;
      },

      # RBAC
      rbac ? {
        create = true;
        aggregateClusterRoles = true;
      },

      # Security contexts
      # Pod-level security context applied to all components.
      securityContext ? {
        runAsNonRoot = true;
        seccompProfile.type = "RuntimeDefault";
      },
      # Container-level security context applied to all components.
      containerSecurityContext ? {
        allowPrivilegeEscalation = false;
        capabilities = { drop = [ "ALL" ]; };
        readOnlyRootFilesystem = true;
      },

      # Prometheus
      prometheus ? { enabled = true; },

      # Webhook
      webhook ? {
        image = {
          repository = "quay.io/jetstack/cert-manager-webhook";
          tag = "v1.19.4";
          pullPolicy = "IfNotPresent";
        };
        replicaCount = 1;
        resources = { };
        securePort = 10250;
        timeoutSeconds = 30;
      },

      # CA Injector
      cainjector ? {
        enabled = true;
        image = {
          repository = "quay.io/jetstack/cert-manager-cainjector";
          tag = "v1.19.4";
          pullPolicy = "IfNotPresent";
        };
        replicaCount = 1;
        resources = { };
      },

      # Startup API Check
      startupapicheck ? {
        enabled = true;
        image = {
          repository = "quay.io/jetstack/cert-manager-startupapicheck";
          tag = "v1.19.4";
          pullPolicy = "IfNotPresent";
        };
        resources = { };
      },
    }:
    self:
    let
      # ── Derived values ───────────────────────────────────────────────

      controllerImageRef = "${image.repository}:${image.tag}";
      webhookImageRef = "${webhook.image.repository}:${webhook.image.tag}";
      cainjectorImageRef = "${cainjector.image.repository}:${cainjector.image.tag}";
      startupapicheckImageRef = "${startupapicheck.image.repository}:${startupapicheck.image.tag}";
      acmeSolverImageRef = "${acmeSolverImage.repository}:${acmeSolverImage.tag}";

      # ── Labels ───────────────────────────────────────────────────────
      # Per-component labels following cert-manager Helm chart conventions.
      # The controller uses "cert-manager" as app name; all others use
      # "cert-manager-<component>".

      mkComponentLabels = component: {
        "app.kubernetes.io/name" =
          if component == "controller" then "cert-manager" else "cert-manager-${component}";
        "app.kubernetes.io/instance" = instance;
        "app.kubernetes.io/component" = component;
        "app.kubernetes.io/managed-by" = "kix";
      } // clusterLabels;

      controllerLabels = mkComponentLabels "controller";
      webhookLabels = mkComponentLabels "webhook";
      cainjectorLabels = mkComponentLabels "cainjector";
      startupapicheckLabels = mkComponentLabels "startupapicheck";

      # Selector labels (subset used for matchLabels)
      mkSelectorLabels = component: {
        "app.kubernetes.io/name" =
          if component == "controller" then "cert-manager" else "cert-manager-${component}";
        "app.kubernetes.io/instance" = instance;
        "app.kubernetes.io/component" = component;
      };

      controllerSelectorLabels = mkSelectorLabels "controller";
      webhookSelectorLabels = mkSelectorLabels "webhook";
      cainjectorSelectorLabels = mkSelectorLabels "cainjector";

      # ── Security contexts ────────────────────────────────────────────

      podSecurityContext = securityContext;
      containerSecCtx = containerSecurityContext;

      # ── Shared values ────────────────────────────────────────────────

      podNamespaceEnv = {
        name = "POD_NAMESPACE";
        valueFrom.fieldRef.fieldPath = "metadata.namespace";
      };

      nodeSelector = {
        "kubernetes.io/os" = "linux";
      };

      prometheusAnnotations = lib.optionalAttrs prometheus.enabled {
        "prometheus.io/path" = "/metrics";
        "prometheus.io/scrape" = "true";
        "prometheus.io/port" = "9402";
      };

      # ── Container specs ──────────────────────────────────────────────
      # Inlined from pkgs/cert-manager/containers.nix, adapted for fixpoint
      # (no kixlib' pipe composition — just plain attrsets with probes merged).

      controllerContainer = {
        name = "cert-manager-controller";
        image = controllerImageRef;
        imagePullPolicy = image.pullPolicy;
        args = [
          "--v=${toString logLevel}"
          "--cluster-resource-namespace=$(POD_NAMESPACE)"
          "--leader-election-namespace=${leaderElection.namespace}"
          "--acme-http01-solver-image=${acmeSolverImageRef}"
          "--max-concurrent-challenges=${toString maxConcurrentChallenges}"
        ];
        ports = [
          { containerPort = 9402; protocol = "TCP"; name = "http-metrics"; }
          { containerPort = 9403; protocol = "TCP"; name = "http-healthz"; }
        ];
        securityContext = containerSecCtx;
        env = [ podNamespaceEnv ];
        livenessProbe = {
          httpGet = { path = "/livez"; port = "http-healthz"; scheme = "HTTP"; };
          initialDelaySeconds = 10;
          periodSeconds = 10;
          timeoutSeconds = 15;
          failureThreshold = 8;
          successThreshold = 1;
        };
      } // lib.optionalAttrs (resources != { }) { inherit resources; };

      webhookContainer = {
        name = "cert-manager-webhook";
        image = webhookImageRef;
        imagePullPolicy = webhook.image.pullPolicy;
        args = [
          "--v=${toString logLevel}"
          "--secure-port=${toString webhook.securePort}"
          "--dynamic-serving-ca-secret-namespace=$(POD_NAMESPACE)"
          "--dynamic-serving-ca-secret-name=cert-manager-webhook-ca"
          "--dynamic-serving-dns-names=cert-manager-webhook"
          "--dynamic-serving-dns-names=cert-manager-webhook.$(POD_NAMESPACE)"
          "--dynamic-serving-dns-names=cert-manager-webhook.$(POD_NAMESPACE).svc"
        ];
        ports = [
          { containerPort = webhook.securePort; protocol = "TCP"; name = "https"; }
          { containerPort = 6080; protocol = "TCP"; name = "healthcheck"; }
          { containerPort = 9402; protocol = "TCP"; name = "http-metrics"; }
        ];
        securityContext = containerSecCtx;
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
      } // lib.optionalAttrs (webhook.resources != { }) {
        resources = webhook.resources;
      };

      cainjectorContainer = {
        name = "cert-manager-cainjector";
        image = cainjectorImageRef;
        imagePullPolicy = cainjector.image.pullPolicy;
        args = [
          "--v=${toString logLevel}"
          "--leader-election-namespace=${leaderElection.namespace}"
        ];
        ports = [
          { containerPort = 9402; protocol = "TCP"; name = "http-metrics"; }
        ];
        securityContext = containerSecCtx;
        env = [ podNamespaceEnv ];
      } // lib.optionalAttrs (cainjector.resources != { }) {
        resources = cainjector.resources;
      };

      startupapicheckContainer = {
        name = "cert-manager-startupapicheck";
        image = startupapicheckImageRef;
        imagePullPolicy = startupapicheck.image.pullPolicy;
        args = [ "check" "api" "--wait=1m" "-v" ];
        securityContext = containerSecCtx;
        env = [ podNamespaceEnv ];
      } // lib.optionalAttrs (startupapicheck.resources != { }) {
        resources = startupapicheck.resources;
      };

      # ── SA name helpers ──────────────────────────────────────────────

      controllerSaName =
        if serviceAccount.create then self.controllerSa.ref else "default";
      webhookSaName =
        if serviceAccount.create then self.webhookSa.ref else "default";
      cainjectorSaName =
        if serviceAccount.create then self.cainjectorSa.ref else "default";
      startupapicheckSaName =
        if serviceAccount.create then self.startupapicheckSa.ref else "default";

    in
    {

      # ====================================================================
      # CONTROLLER RBAC
      # ====================================================================
      #
      # YAML ref direction:   binding -> role, binding -> SA
      # Semantic dep direction: SA -> binding -> role
      #
      # 8 ClusterRoles + 8 ClusterRoleBindings for the controller.
      # Each binding references its role (via ref, auto-tracked) and the
      # controller SA. The SA's requires on all bindings is the inverted dep.

      # --- ClusterRoles ---

      controllerClusterRoleIssuers = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "cert-manager-controller-issuers";
        namespace = null;
        labels = controllerLabels;
        rules = [
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "issuers" "issuers/status" ];
            verbs = [ "update" "patch" ];
          }
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "issuers" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [ "get" "list" "watch" "create" "update" "delete" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "events" ];
            verbs = [ "create" "patch" ];
          }
        ];
      };

      controllerClusterRoleClusterissuers = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "cert-manager-controller-clusterissuers";
        namespace = null;
        labels = controllerLabels;
        rules = [
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "clusterissuers" "clusterissuers/status" ];
            verbs = [ "update" "patch" ];
          }
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "clusterissuers" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [ "get" "list" "watch" "create" "update" "delete" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "events" ];
            verbs = [ "create" "patch" ];
          }
        ];
      };

      controllerClusterRoleCertificates = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "cert-manager-controller-certificates";
        namespace = null;
        labels = controllerLabels;
        rules = [
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "certificates" "certificates/status" "certificaterequests" "certificaterequests/status" ];
            verbs = [ "update" "patch" ];
          }
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "certificates" "certificaterequests" "clusterissuers" "issuers" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "certificates/finalizers" "certificaterequests/finalizers" ];
            verbs = [ "update" ];
          }
          {
            apiGroups = [ "acme.cert-manager.io" ];
            resources = [ "orders" ];
            verbs = [ "create" "delete" "get" "list" "watch" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [ "get" "list" "watch" "create" "update" "delete" "patch" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "events" ];
            verbs = [ "create" "patch" ];
          }
        ];
      };

      controllerClusterRoleOrders = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "cert-manager-controller-orders";
        namespace = null;
        labels = controllerLabels;
        rules = [
          {
            apiGroups = [ "acme.cert-manager.io" ];
            resources = [ "orders" "orders/status" ];
            verbs = [ "update" "patch" ];
          }
          {
            apiGroups = [ "acme.cert-manager.io" ];
            resources = [ "orders" "challenges" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "clusterissuers" "issuers" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "acme.cert-manager.io" ];
            resources = [ "challenges" ];
            verbs = [ "create" "delete" ];
          }
          {
            apiGroups = [ "acme.cert-manager.io" ];
            resources = [ "orders/finalizers" ];
            verbs = [ "update" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "events" ];
            verbs = [ "create" "patch" ];
          }
        ];
      };

      controllerClusterRoleChallenges = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "cert-manager-controller-challenges";
        namespace = null;
        labels = controllerLabels;
        rules = [
          {
            apiGroups = [ "acme.cert-manager.io" ];
            resources = [ "challenges" "challenges/status" ];
            verbs = [ "update" "patch" ];
          }
          {
            apiGroups = [ "acme.cert-manager.io" ];
            resources = [ "challenges" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "issuers" "clusterissuers" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "events" ];
            verbs = [ "create" "patch" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "pods" "services" ];
            verbs = [ "get" "list" "watch" "create" "delete" ];
          }
          {
            apiGroups = [ "networking.k8s.io" ];
            resources = [ "ingresses" ];
            verbs = [ "get" "list" "watch" "create" "delete" "update" ];
          }
          {
            apiGroups = [ "gateway.networking.k8s.io" ];
            resources = [ "httproutes" ];
            verbs = [ "get" "list" "watch" "create" "delete" "update" ];
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
            verbs = [ "get" "list" "watch" ];
          }
        ];
      };

      controllerClusterRoleIngressShim = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "cert-manager-controller-ingress-shim";
        namespace = null;
        labels = controllerLabels;
        rules = [
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "certificates" "certificaterequests" ];
            verbs = [ "create" "update" "delete" ];
          }
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "certificates" "certificaterequests" "issuers" "clusterissuers" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "networking.k8s.io" ];
            resources = [ "ingresses" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "networking.k8s.io" ];
            resources = [ "ingresses/finalizers" ];
            verbs = [ "update" ];
          }
          {
            apiGroups = [ "gateway.networking.k8s.io" ];
            resources = [ "gateways" "httproutes" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "gateway.networking.k8s.io" ];
            resources = [ "gateways/finalizers" "httproutes/finalizers" ];
            verbs = [ "update" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "events" ];
            verbs = [ "create" "patch" ];
          }
        ];
      };

      controllerClusterRoleApprove = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "cert-manager-controller-approve:cert-manager-io";
        namespace = null;
        labels = controllerLabels;
        rules = [
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "signers" ];
            verbs = [ "approve" ];
            resourceNames = [ "issuers.cert-manager.io/*" "clusterissuers.cert-manager.io/*" ];
          }
        ];
      };

      controllerClusterRoleCertificatesigningrequests = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "cert-manager-controller-certificatesigningrequests";
        namespace = null;
        labels = controllerLabels;
        rules = [
          {
            apiGroups = [ "certificates.k8s.io" ];
            resources = [ "certificatesigningrequests" ];
            verbs = [ "get" "list" "watch" "update" ];
          }
          {
            apiGroups = [ "certificates.k8s.io" ];
            resources = [ "certificatesigningrequests/status" ];
            verbs = [ "update" "patch" ];
          }
          {
            apiGroups = [ "certificates.k8s.io" ];
            resources = [ "signers" ];
            verbs = [ "sign" ];
            resourceNames = [ "issuers.cert-manager.io/*" "clusterissuers.cert-manager.io/*" ];
          }
          {
            apiGroups = [ "authorization.k8s.io" ];
            resources = [ "subjectaccessreviews" ];
            verbs = [ "create" ];
          }
        ];
      };

      # --- Controller ClusterRoleBindings (one per ClusterRole) ---

      controllerBindingIssuers = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "cert-manager-controller-issuers";
        namespace = null;
        labels = controllerLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.controllerClusterRoleIssuers.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = controllerSaName; inherit namespace; }];
      };

      controllerBindingClusterissuers = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "cert-manager-controller-clusterissuers";
        namespace = null;
        labels = controllerLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.controllerClusterRoleClusterissuers.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = controllerSaName; inherit namespace; }];
      };

      controllerBindingCertificates = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "cert-manager-controller-certificates";
        namespace = null;
        labels = controllerLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.controllerClusterRoleCertificates.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = controllerSaName; inherit namespace; }];
      };

      controllerBindingOrders = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "cert-manager-controller-orders";
        namespace = null;
        labels = controllerLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.controllerClusterRoleOrders.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = controllerSaName; inherit namespace; }];
      };

      controllerBindingChallenges = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "cert-manager-controller-challenges";
        namespace = null;
        labels = controllerLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.controllerClusterRoleChallenges.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = controllerSaName; inherit namespace; }];
      };

      controllerBindingIngressShim = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "cert-manager-controller-ingress-shim";
        namespace = null;
        labels = controllerLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.controllerClusterRoleIngressShim.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = controllerSaName; inherit namespace; }];
      };

      controllerBindingApprove = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "cert-manager-controller-approve:cert-manager-io";
        namespace = null;
        labels = controllerLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.controllerClusterRoleApprove.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = controllerSaName; inherit namespace; }];
      };

      controllerBindingCertificatesigningrequests = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "cert-manager-controller-certificatesigningrequests";
        namespace = null;
        labels = controllerLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.controllerClusterRoleCertificatesigningrequests.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = controllerSaName; inherit namespace; }];
      };

      # --- Aggregated ClusterRoles (no bindings, just roles with aggregation labels) ---
      # These are conditional on rbac.aggregateClusterRoles but we always define them
      # and let the closure pull them in only when needed.

      aggregatedClusterRoleClusterView = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "cert-manager-cluster-view";
        namespace = null;
        labels = controllerLabels // {
          "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
        };
        rules = [
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "clusterissuers" ];
            verbs = [ "get" "list" "watch" ];
          }
        ];
      };

      aggregatedClusterRoleView = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "cert-manager-view";
        namespace = null;
        labels = controllerLabels // {
          "rbac.authorization.k8s.io/aggregate-to-view" = "true";
          "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
          "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
          "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
        };
        rules = [
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "certificates" "certificaterequests" "issuers" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "acme.cert-manager.io" ];
            resources = [ "challenges" "orders" ];
            verbs = [ "get" "list" "watch" ];
          }
        ];
      };

      aggregatedClusterRoleEdit = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "cert-manager-edit";
        namespace = null;
        labels = controllerLabels // {
          "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
          "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
        };
        rules = [
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "certificates" "certificaterequests" "issuers" ];
            verbs = [ "create" "delete" "deletecollection" "patch" "update" ];
          }
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "certificates/status" ];
            verbs = [ "update" ];
          }
          {
            apiGroups = [ "acme.cert-manager.io" ];
            resources = [ "challenges" "orders" ];
            verbs = [ "create" "delete" "deletecollection" "patch" "update" ];
          }
        ];
      };

      # --- Controller namespaced Roles + RoleBindings ---

      controllerRoleLeaderelection = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = "cert-manager:leaderelection";
        namespace = leaderElection.namespace;
        labels = controllerLabels;
        rules = [
          {
            apiGroups = [ "coordination.k8s.io" ];
            resources = [ "leases" ];
            verbs = [ "get" "update" "patch" ];
            resourceNames = [ "cert-manager-controller" ];
          }
          {
            apiGroups = [ "coordination.k8s.io" ];
            resources = [ "leases" ];
            verbs = [ "create" ];
          }
        ];
      };

      controllerRoleBindingLeaderelection = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "cert-manager:leaderelection";
        namespace = leaderElection.namespace;
        labels = controllerLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = self.controllerRoleLeaderelection.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = controllerSaName; inherit namespace; }];
      };

      controllerRoleTokenrequest = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = "cert-manager-tokenrequest";
        namespace = leaderElection.namespace;
        labels = controllerLabels;
        rules = [
          {
            apiGroups = [ "" ];
            resources = [ "serviceaccounts/token" ];
            verbs = [ "create" ];
            resourceNames = [ "cert-manager" ];
          }
        ];
      };

      controllerRoleBindingTokenrequest = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "cert-manager-tokenrequest";
        namespace = leaderElection.namespace;
        labels = controllerLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = self.controllerRoleTokenrequest.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = controllerSaName; inherit namespace; }];
      };

      # ── Controller ServiceAccount ─────────────────────────────────────

      controllerSa = k8s.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "cert-manager";
        inherit namespace;
        labels = controllerLabels;
        # Inverted dep: the SA is useless without its bindings.
        # All 8 cluster bindings + 2 namespaced bindings are required.
        requires = [
          self.controllerBindingIssuers
          self.controllerBindingClusterissuers
          self.controllerBindingCertificates
          self.controllerBindingOrders
          self.controllerBindingChallenges
          self.controllerBindingIngressShim
          self.controllerBindingApprove
          self.controllerBindingCertificatesigningrequests
          self.controllerRoleBindingLeaderelection
          self.controllerRoleBindingTokenrequest
        ]
        ++ lib.optionals rbac.aggregateClusterRoles [
          self.aggregatedClusterRoleClusterView
          self.aggregatedClusterRoleView
          self.aggregatedClusterRoleEdit
        ];
        extra = lib.optionalAttrs serviceAccount.automountServiceAccountToken {
          automountServiceAccountToken = true;
        };
      };

      # ── Controller Deployment ──────────────────────────────────────────

      controllerDeployment = k8s.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "cert-manager";
        inherit namespace;
        labels = controllerLabels // {
          "app.kubernetes.io/version" = image.tag;
        };
        requires =
          lib.optional serviceAccount.create self.controllerSa;
        spec = {
          replicas = replicaCount;
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

      controllerService = k8s.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "cert-manager";
        inherit namespace;
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

      webhookClusterRoleSubjectaccessreviews = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "cert-manager-webhook:subjectaccessreviews";
        namespace = null;
        labels = webhookLabels;
        rules = [
          {
            apiGroups = [ "authorization.k8s.io" ];
            resources = [ "subjectaccessreviews" ];
            verbs = [ "create" ];
          }
        ];
      };

      webhookBindingSubjectaccessreviews = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "cert-manager-webhook:subjectaccessreviews";
        namespace = null;
        labels = webhookLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.webhookClusterRoleSubjectaccessreviews.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = webhookSaName; inherit namespace; }];
      };

      webhookRoleDynamicServing = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = "cert-manager-webhook:dynamic-serving";
        inherit namespace;
        labels = webhookLabels;
        rules = [
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [ "get" "list" "watch" "update" ];
            resourceNames = [ "cert-manager-webhook-ca" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [ "create" ];
          }
        ];
      };

      webhookRoleBindingDynamicServing = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "cert-manager-webhook:dynamic-serving";
        inherit namespace;
        labels = webhookLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = self.webhookRoleDynamicServing.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = webhookSaName; inherit namespace; }];
      };

      # ── Webhook ServiceAccount ─────────────────────────────────────────

      webhookSa = k8s.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "cert-manager-webhook";
        inherit namespace;
        labels = webhookLabels;
        requires = [
          self.webhookBindingSubjectaccessreviews
          self.webhookRoleBindingDynamicServing
        ];
        extra = lib.optionalAttrs serviceAccount.automountServiceAccountToken {
          automountServiceAccountToken = true;
        };
      };

      # ── Webhook Deployment ─────────────────────────────────────────────

      webhookDeployment = k8s.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "cert-manager-webhook";
        inherit namespace;
        labels = webhookLabels // {
          "app.kubernetes.io/version" = webhook.image.tag;
        };
        requires =
          lib.optional serviceAccount.create self.webhookSa;
        spec = {
          replicas = webhook.replicaCount;
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

      webhookService = k8s.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "cert-manager-webhook";
        inherit namespace;
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
      # These use apiVersion = "admissionregistration.k8s.io/v1" and the
      # `webhooks` top-level field (not under spec).

      mutatingWebhook = k8s.mkResource {
        apiVersion = "admissionregistration.k8s.io/v1";
        kind = "MutatingWebhookConfiguration";
        name = "cert-manager-webhook";
        namespace = null;
        labels = webhookLabels;
        annotations = {
          "cert-manager.io/inject-ca-from-secret" = "${namespace}/cert-manager-webhook-ca";
        };
        webhooks = [
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
            timeoutSeconds = webhook.timeoutSeconds;
            failurePolicy = "Fail";
            sideEffects = "None";
            clientConfig.service = {
              name = "cert-manager-webhook";
              inherit namespace;
              path = "/mutate";
            };
          }
        ];
      };

      validatingWebhook = k8s.mkResource {
        apiVersion = "admissionregistration.k8s.io/v1";
        kind = "ValidatingWebhookConfiguration";
        name = "cert-manager-webhook";
        namespace = null;
        labels = webhookLabels;
        annotations = {
          "cert-manager.io/inject-ca-from-secret" = "${namespace}/cert-manager-webhook-ca";
        };
        webhooks = [
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
                apiGroups = [ "cert-manager.io" "acme.cert-manager.io" ];
                apiVersions = [ "v1" ];
                operations = [ "CREATE" "UPDATE" ];
                resources = [ "*/*" ];
              }
            ];
            admissionReviewVersions = [ "v1" ];
            matchPolicy = "Equivalent";
            timeoutSeconds = webhook.timeoutSeconds;
            failurePolicy = "Fail";
            sideEffects = "None";
            clientConfig.service = {
              name = "cert-manager-webhook";
              inherit namespace;
              path = "/validate";
            };
          }
        ];
      };

      # ====================================================================
      # CA INJECTOR RBAC
      # ====================================================================

      cainjectorClusterRole = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "cert-manager-cainjector";
        namespace = null;
        labels = cainjectorLabels;
        rules = [
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "certificates" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [ "get" "list" "watch" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "events" ];
            verbs = [ "get" "create" "update" "patch" ];
          }
          {
            apiGroups = [ "admissionregistration.k8s.io" ];
            resources = [ "validatingwebhookconfigurations" "mutatingwebhookconfigurations" ];
            verbs = [ "get" "list" "watch" "update" "patch" ];
          }
          {
            apiGroups = [ "apiregistration.k8s.io" ];
            resources = [ "apiservices" ];
            verbs = [ "get" "list" "watch" "update" "patch" ];
          }
          {
            apiGroups = [ "apiextensions.k8s.io" ];
            resources = [ "customresourcedefinitions" ];
            verbs = [ "get" "list" "watch" "update" "patch" ];
          }
        ];
      };

      cainjectorBinding = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "cert-manager-cainjector";
        namespace = null;
        labels = cainjectorLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.cainjectorClusterRole.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = cainjectorSaName; inherit namespace; }];
      };

      cainjectorRoleLeaderelection = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = "cert-manager-cainjector:leaderelection";
        namespace = leaderElection.namespace;
        labels = cainjectorLabels;
        rules = [
          {
            apiGroups = [ "coordination.k8s.io" ];
            resources = [ "leases" ];
            verbs = [ "get" "update" "patch" ];
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

      cainjectorRoleBindingLeaderelection = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "cert-manager-cainjector:leaderelection";
        namespace = leaderElection.namespace;
        labels = cainjectorLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = self.cainjectorRoleLeaderelection.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = cainjectorSaName; inherit namespace; }];
      };

      # ── CA Injector ServiceAccount ─────────────────────────────────────

      cainjectorSa = k8s.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "cert-manager-cainjector";
        inherit namespace;
        labels = cainjectorLabels;
        requires = [
          self.cainjectorBinding
          self.cainjectorRoleBindingLeaderelection
        ];
        extra = lib.optionalAttrs serviceAccount.automountServiceAccountToken {
          automountServiceAccountToken = true;
        };
      };

      # ── CA Injector Deployment ─────────────────────────────────────────

      cainjectorDeployment = k8s.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "cert-manager-cainjector";
        inherit namespace;
        labels = cainjectorLabels // {
          "app.kubernetes.io/version" = cainjector.image.tag;
        };
        requires =
          lib.optional serviceAccount.create self.cainjectorSa;
        spec = {
          replicas = cainjector.replicaCount;
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

      cainjectorService = k8s.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "cert-manager-cainjector";
        inherit namespace;
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

      startupapicheckRoleCreateCert = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = "cert-manager-startupapicheck:create-cert";
        inherit namespace;
        labels = startupapicheckLabels;
        rules = [
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "certificaterequests" ];
            verbs = [ "create" ];
          }
        ];
      };

      startupapicheckRoleBindingCreateCert = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "cert-manager-startupapicheck:create-cert";
        inherit namespace;
        labels = startupapicheckLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = self.startupapicheckRoleCreateCert.ref;
        };
        subjects = [{ kind = "ServiceAccount"; name = startupapicheckSaName; inherit namespace; }];
      };

      # ── Startup API Check ServiceAccount ───────────────────────────────

      startupapicheckSa = k8s.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "cert-manager-startupapicheck";
        inherit namespace;
        labels = startupapicheckLabels;
        requires = [ self.startupapicheckRoleBindingCreateCert ];
        extra = lib.optionalAttrs serviceAccount.automountServiceAccountToken {
          automountServiceAccountToken = true;
        };
      };

      # ── Startup API Check Job ──────────────────────────────────────────

      startupapicheckJob = k8s.mkResource {
        apiVersion = "batch/v1";
        kind = "Job";
        name = "cert-manager-startupapicheck";
        inherit namespace;
        labels = startupapicheckLabels;
        requires =
          lib.optional serviceAccount.create self.startupapicheckSa;
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

      main = k8s.withRequires (
        [ self.controllerDeployment self.webhookService self.mutatingWebhook self.validatingWebhook ]
        ++ lib.optional cainjector.enabled self.cainjectorDeployment
        ++ lib.optional startupapicheck.enabled self.startupapicheckJob
      ) self.controllerService;
    }
  )
  {
    # Default arguments
    namespace = "cert-manager";
  }
