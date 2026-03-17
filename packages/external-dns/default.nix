# External DNS package — v2.
#
# Migrated from pkgs-fp/external-dns/ (v1 fixpoint pattern).
# Source Helm chart: bitnami/external-dns
# https://github.com/bitnami/charts/tree/main/bitnami/external-dns
#
# External DNS synchronizes exposed Kubernetes Services and Ingresses with
# DNS providers (Cloudflare, Route53, etc.). It watches for Services/Ingresses
# with specific annotations and creates/updates DNS records accordingly.
#
# Multi-instance design:
#   This package is designed to run multiple instances in the same cluster.
#   Each instance is identified by `scope.instanceName` (e.g., "cluster-public",
#   "northwind"). The annotation filter ensures each instance only manages DNS
#   records for Services annotated with its specific instance name:
#     lithus.eu/external-dns.resolver in (<instanceName>)
#   This prevents conflicts when multiple External DNS instances coexist.
#
# Resources:
#   - ServiceAccount — per-instance, named "<instanceName>-external-dns"
#   - ClusterRole — read access to services, endpoints, pods, nodes, ingresses.
#     Matches the Bitnami chart's RBAC rules exactly.
#   - ClusterRoleBinding — binds the ClusterRole to the ServiceAccount
#   - Deployment — single-replica controller with provider-specific args
#   - Service — exposes metrics on port 7979 for Prometheus scraping
#
# The `main` resource is the Service — consumers (Prometheus ServiceMonitors,
# network policies) reference it. Deploying the closure includes the Deployment,
# RBAC chain, and everything else needed to make that Service work.

{ scope, config, lib }:

let
  cfg = scope.defaults config {
    image = {
      repository = "bitnamilegacy/external-dns";
      tag = "0.15.1";
      pullPolicy = "IfNotPresent";
    };

    # DNS provider name. Passed as --provider to the binary.
    # Common values: "cloudflare", "aws", "google", "azure"
    provider = "cloudflare";

    # Provider-specific configuration passed as environment variables.
    # Shape depends on provider:
    #   Cloudflare: { apiToken = "..."; proxied = false; }
    #     -> CF_API_TOKEN env var + --cloudflare-proxied flag
    # This is intentionally opaque — each provider has different needs.
    providerConfig = { };

    # Domain filters restrict which DNS zones External DNS manages.
    # Empty = manage all zones the provider credentials can access.
    # Example: [ "example.com" "internal.example.com" ]
    domainFilters = [ ];

    # Annotation filter determines which Services/Ingresses this instance
    # watches. Defaults to the lithus.eu convention for multi-instance
    # deployments. Set to null to use the default, or override with a
    # custom filter string.
    annotationFilter = null;

    # Service type filter — only watch Services of these types.
    # The Bitnami chart defaults to LoadBalancer only, but our clusters
    # also expose ClusterIP and ExternalName services via DNS.
    serviceTypeFilter = [
      "LoadBalancer"
      "ExternalName"
      "ClusterIP"
    ];

    # TXT record prefix — used to avoid conflicts with actual DNS records.
    # Each External DNS instance creates TXT ownership records; this prefix
    # ensures they don't collide with real TXT records.
    txtPrefix = "ext-dns-";

    # TXT owner ID — identifies which External DNS instance owns a record.
    # Defaults to instanceName if null. Important for multi-instance setups
    # to prevent one instance from claiming another's records.
    txtOwnerId = null;

    # Resource requests/limits. These defaults are conservative — External
    # DNS is lightweight (watches API server + talks to DNS provider).
    # CPU spikes during reconciliation loops but is mostly idle.
    resources = {
      requests = {
        cpu = "50m";
        memory = "64Mi";
      };
      limits = {
        cpu = "200m";
        memory = "128Mi";
      };
    };
  };

  # --- Derived values ---

  # Full resource name prefix — all resources are named with this.
  fullname = "${scope.instanceName}-external-dns";

  imageRef = "${cfg.image.repository}:${cfg.image.tag}";

  # Effective annotation filter. If not overridden, uses the lithus.eu
  # convention that ties this instance to a specific resolver name.
  effectiveAnnotationFilter =
    if cfg.annotationFilter != null then
      cfg.annotationFilter
    else
      "lithus.eu/external-dns.resolver in (${scope.instanceName})";

  # Effective TXT owner ID. Falls back to instanceName so each instance
  # has a unique owner identifier for its TXT ownership records.
  effectiveTxtOwnerId =
    if cfg.txtOwnerId != null then cfg.txtOwnerId else scope.instanceName;

  # --- Container args ---
  # Build the argument list for the external-dns binary.
  # Order doesn't matter to the binary, but we group logically:
  #   1. Provider + source configuration
  #   2. Filtering (annotations, domains, service types)
  #   3. TXT record ownership
  #   4. Policy
  containerArgs = [
    "--provider=${cfg.provider}"
    "--source=service"
    "--source=ingress"
    "--annotation-filter=${effectiveAnnotationFilter}"
    "--txt-prefix=${cfg.txtPrefix}"
    "--txt-owner-id=${effectiveTxtOwnerId}"
    "--policy=upsert-only"
  ]
  # --domain-filter is repeated for each domain (not comma-separated).
  # The binary accepts multiple --domain-filter flags.
  ++ map (d: "--domain-filter=${d}") cfg.domainFilters
  # --service-type-filter works the same way — one flag per type.
  ++ map (t: "--service-type-filter=${t}") cfg.serviceTypeFilter
  # Provider-specific flags. Currently only Cloudflare proxied flag
  # is supported. Add more provider flags here as needed.
  ++ lib.optional (cfg.providerConfig ? proxied && !cfg.providerConfig.proxied) "--cloudflare-proxied=false"
  ++ lib.optional (cfg.providerConfig ? proxied && cfg.providerConfig.proxied) "--cloudflare-proxied=true";

  # --- Environment variables ---
  # Provider credentials are passed as env vars, not CLI args (secrets
  # would be visible in `ps` output otherwise). Each provider needs
  # different env vars; we handle Cloudflare here and can extend for others.
  containerEnv = lib.optional (cfg.providerConfig ? apiToken) {
    name = "CF_API_TOKEN";
    value = cfg.providerConfig.apiToken;
  };

  # --- Labels ---
  # selectorLabels: immutable, used in Deployment selector.matchLabels.
  # allLabels: superset on all resources, includes managed-by.
  #
  # We include instanceName in app.kubernetes.io/instance to distinguish
  # multiple External DNS instances in label queries and dashboards.
  selectorLabels = {
    "app.kubernetes.io/instance" = scope.instanceName;
    "app.kubernetes.io/name" = "external-dns";
  };

  allLabels =
    selectorLabels
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

in self: {

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

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = fullname;
    labels = allLabels;
    extra.rules = [
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

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = fullname;
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

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = fullname;
    labels = allLabels;
  };

  # ── Workload ─────────────────────────────────────────────────────
  #
  # Single-replica Deployment. External DNS is stateless — it reads
  # the K8s API and the DNS provider API, reconciling differences.
  # Running multiple replicas would cause duplicate DNS updates and
  # potential race conditions with the provider API, so replica=1
  # is the standard. The TXT ownership records provide leader election
  # of sorts at the DNS level.

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = fullname;
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
          serviceAccountName = "${self.serviceAccount}";
          containers = [
            {
              name = "external-dns";
              image = imageRef;
              imagePullPolicy = cfg.image.pullPolicy;
              args = containerArgs;
              inherit (cfg) resources;
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

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = fullname;
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
  # full RBAC chain are pulled in via requires.

  main = {
    resource = self.service;
    requires = [
      self.deployment
    ];
  };
}
