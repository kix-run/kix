# NetworkPolicy package — Cilium network policies.
#
# Defines Cilium cluster-wide network policies for baseline connectivity
# (DNS, API server, internet egress, ingress-nginx, Prometheus scraping,
# Cilium health checks) and tenant isolation policies that allow traffic
# between namespaces belonging to the same tenant.
#
# Also generates per-namespace CiliumNetworkPolicy resources for
# internal system traffic (allowing traffic between system namespaces
# plus host/kube-apiserver entities).

{
  scope,
  lib,
}:

let
  mkCiliumPolicy =
    { name, spec }:
    scope.mkClusterResource {
      apiVersion = "cilium.io/v2";
      kind = "CiliumClusterwideNetworkPolicy";
      inherit name;
      inherit spec;
    };

  mkTenantPolicy =
    tenantName: tenantCfg:
    mkCiliumPolicy {
      name = "allow-within-tenant-${tenantName}";
      spec = {
        ingress = [
          { }
        ];
        egress = [
          { }
        ];
      };
    };

  # Per-namespace CiliumNetworkPolicy for internal system traffic.
  # Creates a CNP in `nsName` that allows ingress/egress between all
  # namespaces in `allNs` plus host and kube-apiserver entities.
  mkInternalSystemTraffic =
    allNs: nsName:
    let
      nsScope = scope.forNamespace nsName;
      nsMatch = {
        matchExpressions = [
          {
            key = "io.kubernetes.pod.namespace";
            operator = "In";
            values = allNs;
          }
        ];
      };
    in
    nsScope.mkResource {
      apiVersion = "cilium.io/v2";
      kind = "CiliumNetworkPolicy";
      name = "internal-system-traffic";
      spec = {
        egress = [
          { toEndpoints = [ nsMatch ]; }
          {
            toEntities = [
              "host"
              "kube-apiserver"
            ];
          }
        ];
        ingress = [
          { fromEndpoints = [ nsMatch ]; }
          {
            fromEntities = [
              "host"
              "kube-apiserver"
            ];
          }
        ];
      };
    };

in
{
  meta = {
    version = "1.0.0";
    description = "Cilium network policies: cluster-wide baseline connectivity, per-namespace system traffic rules and tenant isolation";
    owner = "platform";
  };

  options = {
    clusterwidePolicies = lib.mkOption {
      type = lib.types.anything;
      default = {
        globalInternetAccess = true;
        globalDns = true;
        kubernetesApiAccess = true;
        ingressNginxAccess = true;
        prometheusScrapingAccess = false;
        ciliumHealthChecks = true;
        fullAccessCidrs = {
          enable = false;
          cidrs = [ ];
        };
        stackgresPrometheusAccess = false;
        stackgresKubeApiAccess = false;
      };
    };
    # DNS target label used in the global-dns policy.
    # Clusters running CoreDNS use "coredns"; those using kube-dns use "kube-dns".
    dnsAppLabel = lib.mkOption {
      type = lib.types.str;
      default = "kube-dns";
    };
    tenants = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    namespacePolicies = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    # Namespaces that get an `internal-system-traffic` CiliumNetworkPolicy
    # allowing mutual ingress/egress between all listed namespaces plus
    # host and kube-apiserver entities.
    internalSystemTraffic = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
      # Optional DI: other packages whose selectors we reference in policies.
      # When present, we use their .out.selector instead of hardcoded labels.
      ingress-nginx ? null,
      kube-prometheus-stack ? null,
      # stackgres-cluster pods get { app = "StackGresCluster"; } assigned by the
      # operator at runtime — no kix package exposes that selector, so we accept
      # an explicit selector override instead.
      stackgres-cluster ? null,
    }:
    let
      cwp = config.clusterwidePolicies;

      # Resolve selectors from DI dependencies, falling back to well-known labels.
      ingressNginxSelector =
        if ingress-nginx != null then
          ingress-nginx.out.selector
        else
          { "app.kubernetes.io/name" = "ingress-nginx"; };

      prometheusSelector =
        if kube-prometheus-stack != null then
          kube-prometheus-stack.out.selector
        else
          { "app.kubernetes.io/name" = "prometheus"; };

      # The StackGres operator labels its managed pods with { app = "StackGresCluster"; }.
      # This is an operator-assigned label, not a kix package selector.
      stackgresClusterSelector =
        if stackgres-cluster != null then stackgres-cluster.out.selector else { app = "StackGresCluster"; };

      # --- Cluster-wide baseline policies ---

      globalInternetAccess = mkCiliumPolicy {
        name = "allow-global-internet-access";
        spec = {
          egress = [
            { toEntities = [ "world" ]; }
          ];
        };
      };

      globalDns = mkCiliumPolicy {
        name = "global-dns";
        spec = {
          egress = [
            {
              toEndpoints = [
                {
                  matchLabels = {
                    "io.kubernetes.pod.namespace" = "kube-system";
                    "k8s-app" = config.dnsAppLabel;
                  };
                }
              ];
              toPorts = [
                {
                  ports = [
                    {
                      port = "53";
                      protocol = "UDP";
                    }
                  ];
                }
              ];
            }
          ];
          ingress = [
            {
              fromEndpoints = [
                {
                  matchLabels = {
                    "io.kubernetes.pod.namespace" = "kube-system";
                    "k8s-app" = config.dnsAppLabel;
                  };
                }
              ];
            }
          ];
        };
      };

      kubernetesApiAccess = mkCiliumPolicy {
        name = "kubernetes-api-access";
        spec = {
          nodeSelector = {
            matchLabels = {
              "node-role.kubernetes.io/master" = "true";
            };
          };
          ingress = [
            {
              fromEntities = [
                "remote-node"
                "health"
                "host"
              ];
            }
            {
              toPorts = [
                {
                  ports = [
                    {
                      port = "443";
                      protocol = "TCP";
                    }
                    {
                      port = "6443";
                      protocol = "TCP";
                    }
                  ];
                }
              ];
            }
          ];
        };
      };

      ingressNginxAccess = mkCiliumPolicy {
        name = "global-access-to-ingress-nginx";
        spec = {
          egress = [
            {
              toEndpoints = [
                { matchLabels = ingressNginxSelector; }
              ];
            }
          ];
          ingress = [
            {
              fromEndpoints = [
                { matchLabels = ingressNginxSelector; }
              ];
            }
          ];
        };
      };

      prometheusScrapingAccess =
        if cwp.prometheusScrapingAccess then
          mkCiliumPolicy {
            name = "allow-prometheus-scraping";
            spec = {
              ingress = [
                {
                  fromEndpoints = [
                    { matchLabels = prometheusSelector; }
                  ];
                }
              ];
            };
          }
        else
          null;

      ciliumHealthChecks = mkCiliumPolicy {
        name = "cilium-health-checks";
        spec = {
          endpointSelector = {
            matchLabels = {
              "reserved:health" = "";
            };
          };
          ingress = [
            {
              fromEntities = [ "all" ];
            }
          ];
        };
      };

      # --- Optional: Full-access CIDRs ---

      fullAccessCidrs = mkCiliumPolicy {
        name = "allow-access-to-full-access-cidrs";
        spec = {
          ingress = [
            {
              fromCIDR = config.clusterwidePolicies.fullAccessCidrs.cidrs;
            }
          ];
        };
      };

      # --- Optional: StackGres Prometheus scraping ---

      stackgresPrometheusAccess = mkCiliumPolicy {
        name = "allow-prometheus-scraping-of-stackgres-clusters";
        spec = {
          endpointSelector = {
            matchLabels = stackgresClusterSelector;
          };
          ingress = [
            {
              fromEndpoints = [
                { matchLabels = prometheusSelector; }
              ];
            }
          ];
        };
      };

      # --- Optional: StackGres kube-api access ---

      stackgresKubeApiAccess = mkCiliumPolicy {
        name = "stackgres-clusters-to-kube-api";
        spec = {
          endpointSelector = {
            matchLabels = stackgresClusterSelector;
          };
          egress = [
            {
              toEntities = [
                "host"
                "kube-apiserver"
              ];
            }
          ];
          ingress = [
            {
              fromEntities = [
                "host"
                "kube-apiserver"
              ];
            }
          ];
        };
      };

      # --- Per-namespace internal system traffic policies ---

      istNamespaces = config.internalSystemTraffic;
      internalSystemTrafficPolicies = builtins.listToAttrs (
        map (nsName: {
          name = "internal-system-traffic-${nsName}";
          value = mkInternalSystemTraffic istNamespaces nsName;
        }) istNamespaces
      );
      internalSystemTrafficList = builtins.attrValues internalSystemTrafficPolicies;

      # --- Tenant isolation policies ---

      tenantPolicies = lib.mapAttrs mkTenantPolicy config.tenants;

      # --- Collect all policies ---

      clusterwidePoliciesList =
        lib.optional cwp.globalInternetAccess globalInternetAccess
        ++ lib.optional cwp.globalDns globalDns
        ++ lib.optional cwp.kubernetesApiAccess kubernetesApiAccess
        ++ lib.optional cwp.ingressNginxAccess ingressNginxAccess
        ++ lib.optional cwp.prometheusScrapingAccess prometheusScrapingAccess
        ++ lib.optional cwp.ciliumHealthChecks ciliumHealthChecks
        ++ lib.optional cwp.fullAccessCidrs.enable fullAccessCidrs
        ++ lib.optional cwp.stackgresPrometheusAccess stackgresPrometheusAccess
        ++ lib.optional cwp.stackgresKubeApiAccess stackgresKubeApiAccess;

      tenantPoliciesList = builtins.attrValues tenantPolicies;

      allPolicies = clusterwidePoliciesList ++ tenantPoliciesList ++ internalSystemTrafficList;

    in
    # Cluster-wide baseline policies
    {
      allow-global-internet-access = globalInternetAccess;
      global-dns = globalDns;
      kubernetes-api-access = kubernetesApiAccess;
      global-access-to-ingress-nginx = ingressNginxAccess;
      allow-prometheus-scraping = prometheusScrapingAccess;
      cilium-health-checks = ciliumHealthChecks;
      allow-access-to-full-access-cidrs = fullAccessCidrs;
      allow-prometheus-scraping-of-stackgres-clusters = stackgresPrometheusAccess;
      stackgres-clusters-to-kube-api = stackgresKubeApiAccess;
    }
    // builtins.listToAttrs (
      lib.mapAttrsToList (
        name: _: lib.nameValuePair "allow-within-tenant-${name}" tenantPolicies.${name}
      ) config.tenants
    )
    // internalSystemTrafficPolicies
    // {
      root = {
        resource = self.global-dns;
        requires = allPolicies;
      };
    };
}
