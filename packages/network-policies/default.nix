# NetworkPolicy package — Cilium cluster-wide network policies.
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
      prometheusScrapingAccess = false;
      ciliumHealthChecks = true;
      fullAccessCidrs = {
        enable = false;
        cidrs = [ ];
      };
      stackgresPrometheusAccess = false;
      stackgresKubeApiAccess = false;
    };
    # DNS target label used in the global-dns policy.
    # Clusters running CoreDNS use "coredns"; those using kube-dns use "kube-dns".
    dnsAppLabel = "kube-dns";
    tenants = { };
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
                "k8s-app" = cfg.dnsAppLabel;
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
                "k8s-app" = cfg.dnsAppLabel;
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
            {
              matchLabels = {
                "app.kubernetes.io/name" = "ingress-nginx";
              };
            }
          ];
        }
      ];
      ingress = [
        {
          fromEndpoints = [
            {
              matchLabels = {
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
      ingress = [
        {
          fromEndpoints = [
            {
              matchLabels = {
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
          fromCIDR = cfg.clusterwidePolicies.fullAccessCidrs.cidrs;
        }
      ];
    };
  };

  # --- Optional: StackGres Prometheus scraping ---

  stackgresPrometheusAccess = mkCiliumPolicy {
    name = "allow-prometheus-scraping-of-stackgres-clusters";
    spec = {
      endpointSelector = {
        matchLabels = {
          app = "StackGresCluster";
        };
      };
      ingress = [
        {
          fromEndpoints = [
            {
              matchLabels = {
                "app.kubernetes.io/name" = "prometheus";
              };
            }
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
        matchLabels = {
          app = "StackGresCluster";
        };
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
    ++ lib.optional cwp.ciliumHealthChecks ciliumHealthChecks
    ++ lib.optional cwp.fullAccessCidrs.enable fullAccessCidrs
    ++ lib.optional cwp.stackgresPrometheusAccess stackgresPrometheusAccess
    ++ lib.optional cwp.stackgresKubeApiAccess stackgresKubeApiAccess;

  tenantPoliciesList = builtins.attrValues tenantPolicies;

  allPolicies = clusterwidePoliciesList ++ tenantPoliciesList;

in
self:
{
  # Cluster-wide baseline policies
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
  ) cfg.tenants
)
// {
  main = {
    resource = self.global-dns;
    requires = allPolicies;
  };
}
