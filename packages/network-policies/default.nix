# NetworkPolicy package — NW1 cluster network policies.
#
# Defines Cilium cluster-wide network policies for baseline connectivity
# (DNS, API server, internet egress, ingress-nginx, Prometheus scraping,
# Cilium health checks) and tenant isolation policies that allow traffic
# between namespaces belonging to the same tenant.
#
# All policies use CiliumClusterwideNetworkPolicy (cluster-scoped).

{
  scope,
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    clusterwidePolicies = {
      globalInternetAccess = true;
      globalDns = true;
      kubernetesApiAccess = true;
      ingressNginxAccess = true;
      prometheusScrapingAccess = true;
      ciliumHealthChecks = true;
    };
    tenants = {
      acme = {
        namespaces = [
          "shopfront-prod"
          "shopfront-stage"
          "shopfront-demo"
        ];
      };
      tidewater = {
        namespaces = [ "ledgerly-prod" ];
      };
      system = {
        namespaces = [
          "kube-system"
          "monitoring-system"
          "nginx-system"
          "cert-manager"
          "cilium-system"
          "openebs"
          "velero"
        ];
      };
    };
    namespacePolicies = { };
  };

  cwp = cfg.clusterwidePolicies;

  mkCiliumPolicy =
    { name, spec }:
    scope.mkClusterResource {
      apiVersion = "cilium.io/v2";
      kind = "CiliumClusterwideNetworkPolicy";
      inherit name;
      inherit spec;
    };

  # --- Cluster-wide baseline policies ---

  globalInternetAccess = mkCiliumPolicy {
    name = "allow-global-internet-access";
    spec = {
      endpointSelector = { };
      egress = [
        { toEntities = [ "world" ]; }
      ];
    };
  };

  globalDns = mkCiliumPolicy {
    name = "global-dns";
    spec = {
      endpointSelector = { };
      egress = [
        {
          toEndpoints = [
            {
              matchLabels = {
                "k8s:io.kubernetes.pod.namespace" = "kube-system";
                "k8s-app" = "kube-dns";
              };
            }
          ];
          toPorts = [
            {
              ports = [
                {
                  port = "53";
                  protocol = "ANY";
                }
              ];
            }
          ];
        }
      ];
    };
  };

  kubernetesApiAccess = mkCiliumPolicy {
    name = "kubernetes-api-access";
    spec = {
      endpointSelector = { };
      egress = [
        { toEntities = [ "kube-apiserver" ]; }
      ];
    };
  };

  ingressNginxAccess = mkCiliumPolicy {
    name = "allow-access-to-ingress-nginx";
    spec = {
      endpointSelector = { };
      egress = [
        {
          toEndpoints = [
            {
              matchLabels = {
                "k8s:io.kubernetes.pod.namespace" = "nginx-system";
                "app.kubernetes.io/name" = "ingress-nginx";
              };
            }
          ];
        }
      ];
    };
  };

  prometheusScrapingAccess = mkCiliumPolicy {
    name = "allow-prometheus-scraping";
    spec = {
      endpointSelector = { };
      ingress = [
        {
          fromEndpoints = [
            {
              matchLabels = {
                "k8s:io.kubernetes.pod.namespace" = "monitoring-system";
                "app.kubernetes.io/name" = "prometheus";
              };
            }
          ];
        }
      ];
    };
  };

  ciliumHealthChecks = mkCiliumPolicy {
    name = "cilium-health-checks";
    spec = {
      endpointSelector = { };
      ingress = [
        {
          fromEndpoints = [
            {
              matchLabels = {
                "reserved:init" = "";
              };
            }
            { matchLabels = { }; }
          ];
          toPorts = [
            {
              ports = [
                {
                  port = "4240";
                  protocol = "TCP";
                }
              ];
            }
          ];
        }
      ];
      egress = [
        {
          toEndpoints = [
            {
              matchLabels = {
                "reserved:init" = "";
              };
            }
            { matchLabels = { }; }
          ];
          toPorts = [
            {
              ports = [
                {
                  port = "4240";
                  protocol = "TCP";
                }
              ];
            }
          ];
        }
      ];
    };
  };

  # --- Tenant isolation policies ---

  mkTenantPolicy =
    tenantName: tenantCfg:
    let
      nsLabels = map (ns: {
        matchLabels = {
          "k8s:io.kubernetes.pod.namespace" = ns;
        };
      }) tenantCfg.namespaces;

    in
    mkCiliumPolicy {
      name = "allow-within-tenant-${tenantName}";
      spec = {
        endpointSelector = {
          matchExpressions = [
            {
              key = "k8s:io.kubernetes.pod.namespace";
              operator = "In";
              values = tenantCfg.namespaces;
            }
          ];
        };
        ingress = [
          { fromEndpoints = nsLabels; }
        ];
        egress = [
          { toEndpoints = nsLabels; }
        ];
      };
    };

  tenantPolicies = lib.mapAttrs mkTenantPolicy cfg.tenants;

  # --- Collect all policies ---

  clusterwidePoliciesList =
    lib.optional cwp.globalInternetAccess globalInternetAccess
    ++ lib.optional cwp.globalDns globalDns
    ++ lib.optional cwp.kubernetesApiAccess kubernetesApiAccess
    ++ lib.optional cwp.ingressNginxAccess ingressNginxAccess
    ++ lib.optional cwp.prometheusScrapingAccess prometheusScrapingAccess
    ++ lib.optional cwp.ciliumHealthChecks ciliumHealthChecks;

  tenantPoliciesList = builtins.attrValues tenantPolicies;

  allPolicies = clusterwidePoliciesList ++ tenantPoliciesList;

in
self:
{
  # Cluster-wide baseline policies
  allow-global-internet-access = globalInternetAccess;
  global-dns = globalDns;
  kubernetes-api-access = kubernetesApiAccess;
  allow-access-to-ingress-nginx = ingressNginxAccess;
  allow-prometheus-scraping = prometheusScrapingAccess;
  cilium-health-checks = ciliumHealthChecks;
}
// builtins.listToAttrs (
  lib.mapAttrsToList (
    name: _: lib.nameValuePair "allow-within-tenant-${name}" tenantPolicies.${name}
  ) cfg.tenants
)
// {
  main = {
    resource = self.global-dns;
    requires = allPolicies;
  };
}
