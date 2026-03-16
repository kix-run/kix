# External DNS package — fixpoint pattern.
#
# Source Helm chart: bitnami/external-dns
# https://github.com/bitnami/charts/tree/main/bitnami/external-dns
#
# External DNS synchronizes exposed Kubernetes Services and Ingresses with
# DNS providers (Cloudflare, Route53, etc.). It watches for Services/Ingresses
# with specific annotations and creates/updates DNS records accordingly.
#
# Multi-instance design:
#   This package is designed to run multiple instances in the same cluster.
#   Each instance is identified by `instanceName` (e.g., "cluster-public",
#   "northwind"). The annotation filter ensures each instance only manages DNS
#   records for Services annotated with its specific instance name:
#     lithus.eu/external-dns.resolver in (<instanceName>)
#   This prevents conflicts when multiple External DNS instances coexist.
#
# Resources:
#   - ServiceAccount — per-instance, named "external-dns-<instanceName>"
#   - ClusterRole — read access to services, endpoints, pods, nodes, ingresses.
#     Matches the Bitnami chart's RBAC rules exactly.
#   - ClusterRoleBinding — binds the ClusterRole to the ServiceAccount
#   - Deployment — single-replica controller with provider-specific args
#   - Service — exposes metrics on port 7979 for Prometheus scraping
#
# Design decisions:
#   - instanceName drives all resource names rather than a generic "name" arg.
#     This makes multi-instance deployments explicit and avoids name collisions.
#   - annotationFilter defaults to the lithus.eu convention but is overridable
#     for clusters that use a different annotation scheme.
#   - providerConfig is an opaque attrset because each DNS provider has
#     different env var requirements (Cloudflare needs CF_API_TOKEN, Route53
#     needs AWS credentials, etc.). The package passes these as container env.
#   - policy is hardcoded to "upsert-only" — External DNS will create and
#     update records but never delete them. This is a safety measure; deletion
#     should be manual. If sync policy is needed, add it as a package arg.
#   - txtPrefix/txtOwnerId prevent record ownership conflicts between
#     instances. Each instance stamps TXT records to track what it owns.

{ k8s, lib }:

k8s.mkPackage
  (
    {
      # --- Package arguments (replaces Helm values.yaml) ---

      namespace ? "kube-system",

      # Instance name — drives all resource names and the default annotation
      # filter. For multi-instance clusters, each instance gets a unique name
      # (e.g., "cluster-public", "northwind").
      instanceName ? "cluster-public",

      image ? {
        repository = "bitnamilegacy/external-dns";
        tag = "0.15.1";
        pullPolicy = "IfNotPresent";
      },

      # DNS provider name. Passed as --provider to the binary.
      # Common values: "cloudflare", "aws", "google", "azure"
      provider ? "cloudflare",

      # Provider-specific configuration passed as environment variables.
      # Shape depends on provider:
      #   Cloudflare: { apiToken = "..."; proxied = false; }
      #     -> CF_API_TOKEN env var + --cloudflare-proxied flag
      # This is intentionally opaque — each provider has different needs.
      providerConfig ? { },

      # Domain filters restrict which DNS zones External DNS manages.
      # Empty = manage all zones the provider credentials can access.
      # Example: [ "example.com" "internal.example.com" ]
      domainFilters ? [ ],

      # Annotation filter determines which Services/Ingresses this instance
      # watches. Defaults to the lithus.eu convention for multi-instance
      # deployments. Set to null to use the default, or override with a
      # custom filter string.
      annotationFilter ? null,

      # Service type filter — only watch Services of these types.
      # The Bitnami chart defaults to LoadBalancer only, but our clusters
      # also expose ClusterIP and ExternalName services via DNS.
      serviceTypeFilter ? [
        "LoadBalancer"
        "ExternalName"
        "ClusterIP"
      ],

      # TXT record prefix — used to avoid conflicts with actual DNS records.
      # Each External DNS instance creates TXT ownership records; this prefix
      # ensures they don't collide with real TXT records.
      txtPrefix ? "ext-dns-",

      # TXT owner ID — identifies which External DNS instance owns a record.
      # Defaults to instanceName if null. Important for multi-instance setups
      # to prevent one instance from claiming another's records.
      txtOwnerId ? null,

      # Resource requests/limits. These defaults are conservative — External
      # DNS is lightweight (watches API server + talks to DNS provider).
      # CPU spikes during reconciliation loops but is mostly idle.
      resources ? {
        requests = {
          cpu = "50m";
          memory = "64Mi";
        };
        limits = {
          cpu = "200m";
          memory = "128Mi";
        };
      },

      # Cluster-wide labels merged into every resource. Injected by the
      # cluster definition (e.g., environment=prod, team=platform).
      clusterLabels ? { },

      # Instance label — used in app.kubernetes.io/instance.
      # Defaults to instanceName so that multi-instance deploys have unique
      # selectorLabels and avoid Services/Deployments cross-selecting pods.
      instance ? instanceName,
    }:
    self:
    let
      # --- Derived values ---

      # Full resource name prefix — all resources are named with this.
      fullname = "external-dns-${instanceName}";

      imageRef = "${image.repository}:${image.tag}";

      # Effective annotation filter. If not overridden, uses the lithus.eu
      # convention that ties this instance to a specific resolver name.
      effectiveAnnotationFilter =
        if annotationFilter != null then
          annotationFilter
        else
          "lithus.eu/external-dns.resolver in (${instanceName})";

      # Effective TXT owner ID. Falls back to instanceName so each instance
      # has a unique owner identifier for its TXT ownership records.
      effectiveTxtOwnerId = if txtOwnerId != null then txtOwnerId else instanceName;

      # --- Container args ---
      # Build the argument list for the external-dns binary.
      # Order doesn't matter to the binary, but we group logically:
      #   1. Provider + source configuration
      #   2. Filtering (annotations, domains, service types)
      #   3. TXT record ownership
      #   4. Policy
      containerArgs = [
        "--provider=${provider}"
        "--source=service"
        "--source=ingress"
        "--annotation-filter=${effectiveAnnotationFilter}"
        "--txt-prefix=${txtPrefix}"
        "--txt-owner-id=${effectiveTxtOwnerId}"
        "--policy=upsert-only"
      ]
      # --domain-filter is repeated for each domain (not comma-separated).
      # The binary accepts multiple --domain-filter flags.
      ++ map (d: "--domain-filter=${d}") domainFilters
      # --service-type-filter works the same way — one flag per type.
      ++ map (t: "--service-type-filter=${t}") serviceTypeFilter
      # Provider-specific flags. Currently only Cloudflare proxied flag
      # is supported. Add more provider flags here as needed.
      ++ lib.optional (providerConfig ? proxied && !providerConfig.proxied) "--cloudflare-proxied=false"
      ++ lib.optional (providerConfig ? proxied && providerConfig.proxied) "--cloudflare-proxied=true";

      # --- Environment variables ---
      # Provider credentials are passed as env vars, not CLI args (secrets
      # would be visible in `ps` output otherwise). Each provider needs
      # different env vars; we handle Cloudflare here and can extend for others.
      containerEnv = lib.optional (providerConfig ? apiToken) {
        name = "CF_API_TOKEN";
        value = providerConfig.apiToken;
      };

      # --- Labels ---
      # selectorLabels: immutable, used in Deployment selector.matchLabels.
      # allLabels: superset on all resources, includes managed-by.
      #
      # We include instanceName in app.kubernetes.io/instance to distinguish
      # multiple External DNS instances in label queries and dashboards.
      selectorLabels = {
        "app.kubernetes.io/instance" = instance;
        "app.kubernetes.io/name" = "external-dns";
      };

      allLabels =
        clusterLabels
        // selectorLabels
        // {
          "app.kubernetes.io/managed-by" = "kix";
        };

      # Pod labels include the k8s-app and tenant labels from the source
      # Helm values. These are used by existing monitoring/network policies
      # and should be preserved for backward compatibility.
      podLabels = selectorLabels // {
        "k8s-app" = "external-dns";
        "tenant" = "system";
      };

    in
    {

      # ── RBAC ─────────────────────────────────────────────────────────
      #
      # External DNS needs read access to services, endpoints, pods, nodes,
      # and ingresses to discover which DNS records to create. It also needs
      # update access to ingress status to write back the assigned DNS names.
      #
      # These rules are taken directly from the Bitnami Helm chart template:
      # templates/clusterrole.yaml
      #
      # YAML ref direction:   binding -> role, binding -> SA
      # Semantic dep direction: SA -> binding -> role

      clusterRole = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = fullname;
        namespace = null; # cluster-scoped
        labels = allLabels;
        rules = [
          # Core API: read services, endpoints, pods, nodes.
          # Services + endpoints are the primary source of DNS records.
          # Pods are needed for headless service endpoint resolution.
          # Nodes are needed for node-port service external IP discovery.
          {
            apiGroups = [ "" ];
            resources = [
              "services"
              "endpoints"
              "pods"
              "nodes"
            ];
            verbs = [
              "get"
              "watch"
              "list"
            ];
          }
          # Ingress resources (both legacy extensions and networking.k8s.io).
          # External DNS creates DNS records for Ingress hosts too.
          {
            apiGroups = [
              "extensions"
              "networking.k8s.io"
            ];
            resources = [ "ingresses" ];
            verbs = [
              "get"
              "watch"
              "list"
            ];
          }
          # Ingress status update — External DNS writes back the DNS name
          # it assigned to the Ingress status.loadBalancer field so other
          # tools (and humans) can see the resolved hostname.
          {
            apiGroups = [ "networking.k8s.io" ];
            resources = [ "ingresses/status" ];
            verbs = [ "update" ];
          }
        ];
      };

      clusterRoleBinding = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = fullname;
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

      serviceAccount = k8s.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = fullname;
        inherit namespace;
        labels = allLabels;
        # Inverted dep: deploying the SA alone is useless without the RBAC
        # chain granting it permissions. The binding references the SA (not
        # the other way around), so we need this manual requires.
        requires = [ self.clusterRoleBinding ];
      };

      # ── Workload ─────────────────────────────────────────────────────
      #
      # Single-replica Deployment. External DNS is stateless — it reads
      # the K8s API and the DNS provider API, reconciling differences.
      # Running multiple replicas would cause duplicate DNS updates and
      # potential race conditions with the provider API, so replica=1
      # is the standard. The TXT ownership records provide leader election
      # of sorts at the DNS level.

      deployment = k8s.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = fullname;
        inherit namespace;
        labels = allLabels;
        requires = [ self.serviceAccount ];
        spec = {
          replicas = 1;
          # Recreate strategy — External DNS should not have two instances
          # running simultaneously (risk of duplicate DNS updates). The
          # default RollingUpdate would briefly run old + new pods together.
          strategy.type = "Recreate";
          selector.matchLabels = selectorLabels;
          template = {
            metadata.labels = podLabels;
            spec = {
              serviceAccountName = self.serviceAccount.ref;
              containers = [
                {
                  name = "external-dns";
                  image = imageRef;
                  imagePullPolicy = image.pullPolicy;
                  args = containerArgs;
                  inherit resources;
                  env = containerEnv;
                  ports = [
                    {
                      # Metrics port — exposed via the Service for Prometheus
                      # scraping. The binary serves /metrics on this port.
                      name = "http-metrics";
                      containerPort = 7979;
                      protocol = "TCP";
                    }
                  ];
                  # Liveness probe hits the /healthz endpoint. External DNS
                  # exposes this on the metrics port.
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = "http-metrics";
                    };
                    initialDelaySeconds = 10;
                    periodSeconds = 10;
                    timeoutSeconds = 5;
                    failureThreshold = 2;
                    successThreshold = 1;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = "http-metrics";
                    };
                    initialDelaySeconds = 5;
                    periodSeconds = 10;
                    timeoutSeconds = 5;
                    failureThreshold = 6;
                    successThreshold = 1;
                  };
                }
              ];
            };
          };
        };
      };

      # ── Service ──────────────────────────────────────────────────────
      #
      # Exposes the metrics endpoint (port 7979) for Prometheus scraping.
      # External DNS doesn't serve user traffic — this Service exists
      # purely for observability. It's the `main` resource because it's
      # the public interface that monitoring infrastructure connects to.

      service = k8s.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = fullname;
        inherit namespace;
        labels = allLabels;
        outputs = {
          metricsPort = 7979;
        };
        spec = {
          type = "ClusterIP";
          selector = selectorLabels;
          ports = [
            {
              name = "http-metrics";
              port = 7979;
              targetPort = "http-metrics";
              protocol = "TCP";
            }
          ];
        };
      };

      # ── Main: the public interface ───────────────────────────────────
      #
      # The Service is the main resource — it's what consumers (Prometheus
      # ServiceMonitors, network policies) reference. The Deployment and
      # full RBAC chain are pulled in via requires/withRequires.

      main = k8s.withRequires [
        self.deployment
      ] self.service;
    }
  )
  {
    # Default arguments — the minimal set needed to deploy.
    # namespace = kube-system because External DNS is a cluster-wide
    # controller that should live alongside other system components.
    namespace = "kube-system";
  }
