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

in
{
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
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      cwp = config.clusterwidePolicies;

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

      prometheusScrapingAccess =
        if cwp.prometheusScrapingAccess then
          mkCiliumPolicy {
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

      allPolicies = clusterwidePoliciesList ++ tenantPoliciesList;

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
    // {
      main = {
        resource = self.global-dns;
        requires = allPolicies;
      };
    };
}
