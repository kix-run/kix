# Ingress NGINX Controller package — fixpoint pattern.
#
# Source Helm chart: ingress-nginx/ingress-nginx
# https://github.com/kubernetes/ingress-nginx
#
# The ingress-nginx controller is a Kubernetes ingress controller using NGINX
# as a reverse proxy and load balancer. It watches Ingress resources and
# configures NGINX accordingly.
#
# NW1 runs three instances of this chart:
#   - public (v1 legacy): LoadBalancer, 3 replicas, class=public, isDefault=true, maxmind
#   - public-v2: LoadBalancer, 3 replicas, class=public-v2
#   - private-v2: ClusterIP, 2 replicas, class=private-v2, whitelist-source-range
#
# Each instance is created via `.override { instanceName = "..."; ... }`.
# The `instanceName` parameter drives ALL resource names, so multiple instances
# can coexist in the same namespace without collisions.
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
#     arg to enable GeoIP2 database downloads for geo-based routing. Only the
#     public v1 legacy instance uses this in NW1.

{ k8s, lib }:

k8s.mkPackage
  (
    {
      # --- Package arguments (replaces Helm values.yaml) ---

      namespace ? "nginx-system",

      # Instance name — drives ALL resource names. Each instance of ingress-nginx
      # in a cluster needs a unique instanceName to avoid resource collisions.
      # Examples: "public", "public-v2", "private-v2".
      instanceName ? "public",

      image ? {
        repository = "registry.k8s.io/ingress-nginx/controller";
        tag = "v1.12.1";
        pullPolicy = "IfNotPresent";
      },

      # Deployment or DaemonSet. NW1 uses Deployment for all instances.
      # DaemonSet would be useful for bare-metal clusters where you want one
      # controller per node.
      controllerKind ? "Deployment",

      replicaCount ? 3,

      # Service type: LoadBalancer for public-facing, ClusterIP for internal.
      serviceType ? "LoadBalancer",

      # Explicit clusterIP — only meaningful when serviceType = "ClusterIP".
      # Set to a specific IP for stable internal DNS, or null for auto-assignment.
      clusterIP ? null,

      # IngressClass name. Defaults to instanceName if null. This is the value
      # users put in `ingressClassName` on their Ingress resources to target
      # this controller.
      ingressClassName ? null,

      # Whether this IngressClass is the cluster default. Only ONE class should
      # be default — if an Ingress omits ingressClassName, K8s routes it here.
      isDefaultClass ? false,

      # Controller class value for the IngressClass spec.controller field.
      # Defaults to "k8s.io/ingress-nginx-<instanceName>". Must be unique
      # per controller instance — this is how the controller binary knows
      # which IngressClass it owns.
      controllerValue ? null,

      # NGINX configuration passed as ConfigMap data. These map directly to
      # NGINX directives. See: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/configmap/
      config ? {
        proxy-body-size = "200M";
        use-forwarded-headers = "true";
        # annotations-risk-level controls which annotations are allowed.
        # "Critical" allows all annotations including potentially dangerous ones
        # like server-snippet. Required for complex routing setups.
        annotations-risk-level = "Critical";
      },

      # Allow snippet annotations (server-snippet, configuration-snippet).
      # Security risk but needed for advanced routing patterns.
      allowSnippetAnnotations ? true,

      # MaxMind GeoIP2 license key. When set, the controller downloads the
      # GeoIP2 database on startup for geo-based routing decisions.
      # Only needed for the legacy public instance in NW1.
      maxmindLicenseKey ? null,

      # Whether to enable the default backend. When true, the controller
      # serves a default 404 page for unmatched requests.
      defaultBackendEnabled ? true,

      # Pod anti-affinity: spread controller pods across nodes and AZs.
      # Uses preferredDuringSchedulingIgnoredDuringExecution (soft) to avoid
      # scheduling failures in small clusters.
      enableAntiAffinity ? true,

      resources ? {
        requests = {
          cpu = "100m";
          memory = "90Mi";
        };
        limits = {
          cpu = "1";
          memory = "256Mi";
        };
      },

      # Cluster-wide labels merged into every resource.
      clusterLabels ? { },

      # Instance label value — used in app.kubernetes.io/instance.
      # For multi-instance packages this MUST be unique per instance to avoid
      # selector collisions (Services/Deployments would cross-select pods).
      # Defaults to instanceName so that multi-instance deploys are safe
      # out of the box.
      instance ? instanceName,
    }:
    self:
    let
      # --- Derived values ---
      imageRef = "${image.repository}:${image.tag}";

      # Resolve defaulted values. Using `or` pattern: if the user passes null,
      # we fall back to a sensible default derived from instanceName.
      resolvedIngressClassName = if ingressClassName != null then ingressClassName else instanceName;
      # controllerValue: the IngressClass spec.controller string. Must match
      # between the IngressClass resource and the --controller-class arg.
      # Default uses the lithus.eu domain to match the existing Ansible/Helm
      # convention (was `{{ domain }}/{{ instance_name }}`).
      resolvedControllerValue =
        if controllerValue != null then controllerValue else "k8s.io/ingress-nginx-${instanceName}";

      # Resource name helpers — all resources are namespaced under instanceName
      # to allow multiple instances in the same cluster/namespace.
      saName = "${instanceName}-ingress-nginx";
      configmapName = "${instanceName}-ingress-nginx-controller";
      controllerName = "${instanceName}-controller";

      # --- Labels ---
      # selectorLabels: immutable, used in Deployment selector.matchLabels.
      # We include a component label because ingress-nginx traditionally has
      # multiple components (controller, default-backend, etc.).
      selectorLabels = {
        "app.kubernetes.io/instance" = instance;
        "app.kubernetes.io/name" = "ingress-nginx";
        "app.kubernetes.io/component" = "controller";
      };

      allLabels =
        clusterLabels
        // selectorLabels
        // {
          "app.kubernetes.io/managed-by" = "kix";
        };

      # --- Anti-affinity spec ---
      # preferredDuringSchedulingIgnoredDuringExecution with two terms:
      #   1. Spread across hostnames (weight 100) — avoid two controllers on same node
      #   2. Spread across AZs (weight 50) — survive AZ failure
      # topology.lithus.eu/az is a custom topology key used in NW1 clusters.
      antiAffinitySpec = lib.optionalAttrs enableAntiAffinity {
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

      # --- Controller container args ---
      # These flags configure which IngressClass the controller watches,
      # how it participates in leader election, and where to find its ConfigMap.
      controllerArgs = [
        "--ingress-class=${resolvedIngressClassName}"
        "--controller-class=${resolvedControllerValue}"
        "--election-id=${instanceName}-leader"
        # The controller reads its NGINX config from this ConfigMap.
        # Format: <namespace>/<configmap-name>. We use k8s.str to preserve
        # the ref tracking on the configmap name.
        (k8s.str [
          "--configmap="
          namespace
          "/"
          self.configmap.ref
        ])
      ]
      ++ lib.optional allowSnippetAnnotations "--enable-annotation-validation=false"
      ++ lib.optional (maxmindLicenseKey != null) "--maxmind-license-key=${maxmindLicenseKey}"
      # Note: --default-backend-service is intentionally omitted. The Helm chart
      # creates a separate default backend Deployment + Service, but we don't
      # translate that. The ingress-nginx controller serves its own default 404
      # page when no default backend is configured, which is sufficient.
      ;

    in
    {

      # ── RBAC (cluster-scoped) ──────────────────────────────────────
      #
      # The controller needs cluster-wide read access to watch Ingress
      # resources, Services, Endpoints, Secrets (for TLS certs), etc.
      # across ALL namespaces. It also needs to update Ingress status
      # (to write the LoadBalancer IP) and create events.
      #
      # Rules taken directly from the ingress-nginx Helm chart.

      clusterRole = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = saName;
        namespace = null; # cluster-scoped
        labels = allLabels;
        rules = [
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

      clusterRoleBinding = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = saName;
        namespace = null; # cluster-scoped
        labels = allLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.clusterRole.ref; # auto-tracked dep
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.ref; # auto-tracked dep
            inherit namespace;
          }
        ];
      };

      # ── RBAC (namespace-scoped) ────────────────────────────────────
      #
      # Leader election uses a Lease (or ConfigMap in older versions) in
      # the controller's own namespace. The namespace-scoped Role grants
      # just enough access for this — no cluster-wide configmap/lease
      # write access needed.

      role = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = saName;
        inherit namespace;
        labels = allLabels;
        rules = [
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

      roleBinding = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = saName;
        inherit namespace;
        labels = allLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = self.role.ref; # auto-tracked dep
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.ref; # auto-tracked dep
            inherit namespace;
          }
        ];
      };

      # ── ServiceAccount ─────────────────────────────────────────────
      #
      # Requires both bindings (inverted deps): the SA is useless without
      # the cluster-scoped AND namespace-scoped RBAC grants. Both are
      # needed — cluster for watching ingresses, namespace for leader election.

      serviceAccount = k8s.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = saName;
        inherit namespace;
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

      configmap = k8s.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = configmapName;
        inherit namespace;
        labels = allLabels;
        data = config;
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
      #
      # We use `extra` for spec.controller because IngressClass has a
      # non-standard structure (spec.controller is a plain string, not
      # a typical spec object).

      ingressClass = k8s.mkResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "IngressClass";
        name = resolvedIngressClassName;
        namespace = null; # cluster-scoped
        labels = allLabels;
        annotations = lib.optionalAttrs isDefaultClass {
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

      deployment = k8s.mkResource {
        apiVersion = "apps/v1";
        kind = controllerKind;
        name = controllerName;
        inherit namespace;
        labels = allLabels // {
          "app.kubernetes.io/version" = image.tag;
        };
        # Explicit requires:
        #   - serviceAccount: also auto-tracked via .ref, but listing for
        #     clarity and to pull in the SA's transitive RBAC deps
        #   - ingressClass: cluster-scoped resource the controller needs
        #   - configmap: referenced via k8s.str in args, auto-tracked
        requires = [
          self.serviceAccount
          self.ingressClass
        ];
        spec = {
          replicas = replicaCount;
          selector.matchLabels = selectorLabels;
          template = {
            metadata.labels = selectorLabels;
            spec = {
              serviceAccountName = self.serviceAccount.ref;
              containers = [
                {
                  name = "controller";
                  image = imageRef;
                  imagePullPolicy = image.pullPolicy;
                  inherit resources;
                  args = controllerArgs;
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

      service = k8s.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = controllerName;
        inherit namespace;
        labels = allLabels;
        outputs = {
          httpPort = 80;
          httpsPort = 443;
        };
        spec = {
          type = serviceType;
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
        // lib.optionalAttrs (clusterIP != null) {
          clusterIP = clusterIP;
        };
      };

      # ── Main: the public interface ─────────────────────────────────
      #
      # From outside, ingress-nginx IS the Service — traffic flows through
      # it to reach the controller pods. Deploying main.closure includes
      # the Deployment (which pulls in RBAC + ConfigMap via auto-tracking
      # and requires), the IngressClass, and the Service itself.
      #
      # The deployment is listed in withRequires to ensure the full closure
      # is correct. The IngressClass and ConfigMap are already in the
      # deployment's requires/deps, so they come along transitively.

      main = k8s.withRequires [
        self.deployment
        self.ingressClass
        self.configmap
      ] self.service;
    }
  )
  {
    # Default arguments — the minimal set for a basic deployment.
    # nginx-system is the conventional namespace for ingress controllers,
    # keeping them isolated from application workloads.
    namespace = "nginx-system";
  }
