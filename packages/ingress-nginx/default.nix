# Ingress NGINX Controller package — v2.
#
# Migrated from pkgs-fp/ingress-nginx/ (v1 fixpoint pattern).
# Source Helm chart: ingress-nginx/ingress-nginx
# https://github.com/kubernetes/ingress-nginx
#
# The ingress-nginx controller is a Kubernetes ingress controller using NGINX
# as a reverse proxy and load balancer. It watches Ingress resources and
# configures NGINX accordingly.
#
# Multi-instance design:
#   Each instance is identified by `scope.instanceName` (e.g., "public",
#   "public-v2", "private-v2"). The instanceName drives ALL resource names,
#   so multiple instances can coexist in the same namespace without collisions.
#
# Resources per instance:
#   - ServiceAccount: <instanceName>-ingress-nginx
#   - ClusterRole: <instanceName>-ingress-nginx (broad read access for ingresses, services, etc.)
#   - ClusterRoleBinding: <instanceName>-ingress-nginx
#   - Role: <instanceName>-ingress-nginx (namespace-scoped for leases, configmaps — leader election)
#   - RoleBinding: <instanceName>-ingress-nginx
#   - ConfigMap: <instanceName>-ingress-nginx-controller (NGINX tuning: proxy-body-size, etc.)
#   - Deployment: <instanceName>-controller (the actual NGINX pods)
#   - Service: <instanceName>-controller (LoadBalancer or ClusterIP, ports 80/443)
#   - IngressClass: <instanceName> (cluster-scoped, maps to this controller instance)
#
# Design decisions:
#   - `main` is the Service because consumers route traffic through it. Deploying
#     main.closure pulls in the Deployment, RBAC, ConfigMap, and IngressClass.
#   - IngressClass is always created (no conditional gating). Every ingress-nginx
#     instance needs exactly one IngressClass — without it the controller won't
#     claim any Ingress resources.
#   - Both ClusterRole+ClusterRoleBinding (cluster-wide) AND Role+RoleBinding
#     (namespace-scoped) are needed. The cluster-scoped RBAC gives read access to
#     ingresses/services/etc across all namespaces. The namespace-scoped RBAC
#     handles leader election (leases) and configmap access within the controller's
#     own namespace.
#   - Anti-affinity is opt-in (enableAntiAffinity) and uses
#     preferredDuringSchedulingIgnoredDuringExecution — soft preference, not hard
#     requirement. This avoids scheduling failures in small clusters while still
#     spreading pods in larger ones.
#   - maxmindLicenseKey is nullable. When set, it adds the --maxmind-license-key
#     arg to enable GeoIP2 database downloads for geo-based routing.

{ scope, config, lib }:

let
  cfg = scope.defaults config {
    image = {
      repository = "registry.k8s.io/ingress-nginx/controller";
      tag = "v1.12.1";
      pullPolicy = "IfNotPresent";
    };

    # Deployment or DaemonSet. Deployment is typical for cloud clusters.
    # DaemonSet would be useful for bare-metal clusters where you want one
    # controller per node.
    controllerKind = "Deployment";

    replicaCount = 3;

    # Service type: LoadBalancer for public-facing, ClusterIP for internal.
    serviceType = "LoadBalancer";

    # Explicit clusterIP — only meaningful when serviceType = "ClusterIP".
    # Set to a specific IP for stable internal DNS, or null for auto-assignment.
    clusterIP = null;

    # IngressClass name. Defaults to instanceName if null. This is the value
    # users put in `ingressClassName` on their Ingress resources to target
    # this controller.
    ingressClassName = null;

    # Whether this IngressClass is the cluster default. Only ONE class should
    # be default — if an Ingress omits ingressClassName, K8s routes it here.
    isDefaultClass = false;

    # Controller class value for the IngressClass spec.controller field.
    # Defaults to "k8s.io/ingress-nginx-<instanceName>". Must be unique
    # per controller instance — this is how the controller binary knows
    # which IngressClass it owns.
    controllerValue = null;

    # NGINX configuration passed as ConfigMap data. These map directly to
    # NGINX directives. See: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/configmap/
    config = {
      proxy-body-size = "200M";
      use-forwarded-headers = "true";
      # annotations-risk-level controls which annotations are allowed.
      # "Critical" allows all annotations including potentially dangerous ones
      # like server-snippet. Required for complex routing setups.
      annotations-risk-level = "Critical";
    };

    # Allow snippet annotations (server-snippet, configuration-snippet).
    # Security risk but needed for advanced routing patterns.
    allowSnippetAnnotations = true;

    # MaxMind GeoIP2 license key. When set, the controller downloads the
    # GeoIP2 database on startup for geo-based routing decisions.
    maxmindLicenseKey = null;

    # Whether to enable the default backend. When true, the controller
    # serves a default 404 page for unmatched requests.
    defaultBackendEnabled = true;

    # Pod anti-affinity: spread controller pods across nodes and AZs.
    # Uses preferredDuringSchedulingIgnoredDuringExecution (soft) to avoid
    # scheduling failures in small clusters.
    enableAntiAffinity = true;

    resources = {
      requests = {
        cpu = "100m";
        memory = "90Mi";
      };
      limits = {
        cpu = "1";
        memory = "256Mi";
      };
    };
  };

  # --- Derived values ---
  imageRef = "${cfg.image.repository}:${cfg.image.tag}";

  # Resolve defaulted values. Using `or` pattern: if the user passes null,
  # we fall back to a sensible default derived from instanceName.
  resolvedIngressClassName =
    if cfg.ingressClassName != null then cfg.ingressClassName else scope.instanceName;

  # controllerValue: the IngressClass spec.controller string. Must match
  # between the IngressClass resource and the --controller-class arg.
  resolvedControllerValue =
    if cfg.controllerValue != null then cfg.controllerValue else "k8s.io/ingress-nginx-${scope.instanceName}";

  # Resource name helpers — all resources are namespaced under instanceName
  # to allow multiple instances in the same cluster/namespace.
  saName = "${scope.instanceName}-ingress-nginx";
  configmapName = "${scope.instanceName}-ingress-nginx-controller";
  controllerName = "${scope.instanceName}-controller";

  # --- Labels ---
  # selectorLabels: immutable, used in Deployment selector.matchLabels.
  # We include a component label because ingress-nginx traditionally has
  # multiple components (controller, default-backend, etc.).
  selectorLabels = {
    "app.kubernetes.io/instance" = scope.instanceName;
    "app.kubernetes.io/name" = "ingress-nginx";
    "app.kubernetes.io/component" = "controller";
  };

  allLabels =
    selectorLabels
    // {
      "app.kubernetes.io/managed-by" = "kix";
    };

  # --- Anti-affinity spec ---
  # preferredDuringSchedulingIgnoredDuringExecution with two terms:
  #   1. Spread across hostnames (weight 100) — avoid two controllers on same node
  #   2. Spread across AZs (weight 50) — survive AZ failure
  # topology.lithus.eu/az is a custom topology key used in NW1 clusters.
  antiAffinitySpec = lib.optionalAttrs cfg.enableAntiAffinity {
    affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
      {
        weight = 100;
        podAffinityTerm = {
          labelSelector.matchLabels = selectorLabels;
          topologyKey = "kubernetes.io/hostname";
        };
      }
      {
        weight = 50;
        podAffinityTerm = {
          labelSelector.matchLabels = selectorLabels;
          topologyKey = "topology.lithus.eu/az";
        };
      }
    ];
  };

in self: {

  # ── RBAC (cluster-scoped) ──────────────────────────────────────
  #
  # The controller needs cluster-wide read access to watch Ingress
  # resources, Services, Endpoints, Secrets (for TLS certs), etc.
  # across ALL namespaces. It also needs to update Ingress status
  # (to write the LoadBalancer IP) and create events.
  #
  # Rules taken directly from the ingress-nginx Helm chart.

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = saName;
    labels = allLabels;
    extra.rules = [
      # Core resources: the controller watches these to know which
      # backends exist and how to route traffic.
      {
        apiGroups = [ "" ];
        resources = [
          "configmaps"
          "endpoints"
          "nodes"
          "pods"
          "secrets"
          "namespaces"
        ];
        verbs = [
          "list"
          "watch"
        ];
      }
      # Coordination: watch leases for leader election visibility.
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        verbs = [
          "list"
          "watch"
        ];
      }
      # Nodes: get individual node info for topology-aware routing.
      {
        apiGroups = [ "" ];
        resources = [ "nodes" ];
        verbs = [ "get" ];
      }
      # Services: full read access needed to build upstream configs.
      {
        apiGroups = [ "" ];
        resources = [ "services" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      # Ingresses: the primary resource this controller manages.
      {
        apiGroups = [ "networking.k8s.io" ];
        resources = [ "ingresses" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      # Events: the controller creates events on Ingress resources
      # to report configuration reload status.
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
      # Ingress status: update to write the LoadBalancer IP/hostname
      # so `kubectl get ingress` shows the correct ADDRESS column.
      {
        apiGroups = [ "networking.k8s.io" ];
        resources = [ "ingresses/status" ];
        verbs = [ "update" ];
      }
      # IngressClasses: the controller needs to read these to know
      # which class it's responsible for.
      {
        apiGroups = [ "networking.k8s.io" ];
        resources = [ "ingressclasses" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      # EndpointSlices: newer alternative to Endpoints, used for
      # service discovery in K8s 1.21+.
      {
        apiGroups = [ "discovery.k8s.io" ];
        resources = [ "endpointslices" ];
        verbs = [
          "list"
          "watch"
          "get"
        ];
      }
    ];
  };

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = saName;
    labels = allLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.clusterRole}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "${self.serviceAccount}";
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  # ── RBAC (namespace-scoped) ────────────────────────────────────
  #
  # Leader election uses a Lease (or ConfigMap in older versions) in
  # the controller's own namespace. The namespace-scoped Role grants
  # just enough access for this — no cluster-wide configmap/lease
  # write access needed.

  role = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = saName;
    labels = allLabels;
    extra.rules = [
      # ConfigMaps: the controller stores its leader election state
      # and dynamic configuration in namespace-local ConfigMaps.
      {
        apiGroups = [ "" ];
        resources = [ "configmaps" ];
        verbs = [
          "get"
          "create"
          "update"
        ];
      }
      # Leases: modern leader election mechanism (K8s 1.14+).
      # The controller creates a Lease object and renews it periodically.
      # If it fails to renew, another replica takes over.
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        verbs = [
          "get"
          "create"
          "update"
        ];
      }
    ];
  };

  roleBinding = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = saName;
    labels = allLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.role}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "${self.serviceAccount}";
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  # ── ServiceAccount ─────────────────────────────────────────────
  #
  # Requires both bindings (inverted deps): the SA is useless without
  # the cluster-scoped AND namespace-scoped RBAC grants. Both are
  # needed — cluster for watching ingresses, namespace for leader election.

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = saName;
    labels = allLabels;
    # Inverted deps: bindings reference the SA (not vice versa), but
    # deploying a SA without its bindings is useless.
    requires = [
      self.clusterRoleBinding
      self.roleBinding
    ];
  };

  # ── ConfigMap ──────────────────────────────────────────────────
  #
  # NGINX configuration passed to the controller via --configmap flag.
  # All keys map to NGINX directives or controller behaviors.
  # See: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/configmap/
  #
  # The controller watches this ConfigMap and triggers an NGINX reload
  # when it changes (no pod restart needed).

  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = configmapName;
    labels = allLabels;
    data = cfg.config;
  };

  # ── IngressClass ───────────────────────────────────────────────
  #
  # Cluster-scoped resource that maps a class name to a controller.
  # Users reference this via `spec.ingressClassName` on their Ingress
  # resources. The controller only processes Ingresses that match its
  # IngressClass.
  #
  # The `spec.controller` field must match the --controller-class arg
  # passed to the controller binary. This is how K8s routes the
  # Ingress to the correct controller instance.

  ingressClass = scope.mkClusterResource {
    apiVersion = "networking.k8s.io/v1";
    kind = "IngressClass";
    name = resolvedIngressClassName;
    labels = allLabels;
    annotations = lib.optionalAttrs cfg.isDefaultClass {
      "ingressclass.kubernetes.io/is-default-class" = "true";
    };
    extra = {
      spec.controller = resolvedControllerValue;
    };
  };

  # ── Deployment ─────────────────────────────────────────────────
  #
  # The NGINX controller pods. Each pod runs the ingress-nginx-controller
  # binary which:
  #   1. Watches the K8s API for Ingress, Service, Endpoint changes
  #   2. Generates an nginx.conf from the current state
  #   3. Reloads NGINX when the config changes
  #
  # The controller listens on ports 80 (HTTP) and 443 (HTTPS) and
  # proxies traffic to backend Services based on Ingress rules.

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = cfg.controllerKind;
    name = controllerName;
    labels = allLabels // {
      "app.kubernetes.io/version" = cfg.image.tag;
    };
    # Explicit requires:
    #   - serviceAccount: also auto-tracked via interpolation, but listing for
    #     clarity and to pull in the SA's transitive RBAC deps
    #   - ingressClass: cluster-scoped resource the controller needs
    requires = [
      self.serviceAccount
      self.ingressClass
    ];
    spec = {
      replicas = cfg.replicaCount;
      selector.matchLabels = selectorLabels;
      template = {
        metadata.labels = selectorLabels;
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          containers = [
            {
              name = "controller";
              image = imageRef;
              imagePullPolicy = cfg.image.pullPolicy;
              inherit (cfg) resources;
              args = [
                "--ingress-class=${resolvedIngressClassName}"
                "--controller-class=${resolvedControllerValue}"
                "--election-id=${scope.instanceName}-leader"
                # The controller reads its NGINX config from this ConfigMap.
                # Format: <namespace>/<configmap-name>.
                "--configmap=${scope.namespaceName}/${self.configmap}"
              ]
              ++ lib.optional cfg.allowSnippetAnnotations "--enable-annotation-validation=false"
              ++ lib.optional (cfg.maxmindLicenseKey != null) "--maxmind-license-key=${cfg.maxmindLicenseKey}";
              ports = [
                {
                  name = "http";
                  containerPort = 80;
                  protocol = "TCP";
                }
                {
                  name = "https";
                  containerPort = 443;
                  protocol = "TCP";
                }
              ];
              # Liveness and readiness probes. The controller exposes
              # /healthz on port 10254 (hardcoded in the binary).
              livenessProbe = {
                httpGet = {
                  path = "/healthz";
                  port = 10254;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 10;
                periodSeconds = 10;
                timeoutSeconds = 1;
                failureThreshold = 5;
                successThreshold = 1;
              };
              readinessProbe = {
                httpGet = {
                  path = "/healthz";
                  port = 10254;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 10;
                periodSeconds = 10;
                timeoutSeconds = 1;
                failureThreshold = 3;
                successThreshold = 1;
              };
            }
          ];
        }
        # Anti-affinity is merged into pod spec when enabled.
        # Uses // because antiAffinitySpec is either {} or { affinity = ...; }.
        // antiAffinitySpec;
      };
    };
  };

  # ── Service ────────────────────────────────────────────────────
  #
  # The entry point for all ingress traffic. LoadBalancer type gets a
  # cloud provider LB (AWS NLB/ALB, GCP LB, etc.), ClusterIP is for
  # internal-only access (e.g., private-v2 behind a VPN).
  #
  # Ports 80 and 443 map directly to the controller container ports.
  # The controller handles TLS termination internally (via Secrets
  # referenced in Ingress TLS blocks), so both ports target the same
  # container ports.

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = controllerName;
    labels = allLabels;
    outputs = {
      httpPort = 80;
      httpsPort = 443;
    };
    spec = {
      type = cfg.serviceType;
      selector = selectorLabels;
      ports = [
        {
          name = "http";
          port = 80;
          protocol = "TCP";
          targetPort = 80;
        }
        {
          name = "https";
          port = 443;
          protocol = "TCP";
          targetPort = 443;
        }
      ];
    }
    # clusterIP is only set when explicitly provided (for stable internal IPs).
    # Omitting it lets K8s auto-assign. For LoadBalancer type this field is
    # typically left unset.
    // lib.optionalAttrs (cfg.clusterIP != null) {
      clusterIP = cfg.clusterIP;
    };
  };

  # ── Main: the public interface ─────────────────────────────────
  #
  # From outside, ingress-nginx IS the Service — traffic flows through
  # it to reach the controller pods. Deploying main.closure includes
  # the Deployment (which pulls in RBAC + ConfigMap via auto-tracking
  # and requires), the IngressClass, and the Service itself.

  main = self.service // {
    requires = [
      self.deployment
      self.ingressClass
      self.configmap
    ];
  };
}
