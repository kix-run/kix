# Flavor: kind — Kubernetes in Docker, for local development and CI.
#
# Pre-installs: kindnet CNI, standard StorageClass (local, ephemeral).
# Volumes do not survive container restarts. No LoadBalancer support.
#
# Platform imports: DNS (coredns, bundled), storage (standard, ephemeral).
# Platform intents: when networkPolicy.enable = true, declares connectivity
# for kind's non-kix-managed system pods so they aren't blocked by Cilium's
# `always` enforcement mode. CoreDNS intents live on the platform-dns
# import (so the marker depends on its CNPs → enforcer chain). Intents
# for pods without an import (local-path-provisioner) stay in
# networkPolicy.platformIntents.

{
  lib,
  kix,
  config,
  ...
}:
{
  cluster.provider = lib.mkDefault "kind";

  cluster.capabilities = {
    multiNode = lib.mkDefault false;
    loadBalancer = lib.mkDefault false;
    cni = lib.mkDefault "kindnet";
    networkPolicyAPI = lib.mkDefault "none"; # kindnet has no enforcement
    persistentStorage = lib.mkDefault false; # volumes are ephemeral (docker container FS)
    rwxStorage = lib.mkDefault false;
    volumeSnapshots = lib.mkDefault false;
  };

  # Platform-provided imports.
  instances.kube-system = {
    platform-dns = {
      package = kix.mkImport {
        kind = "Deployment";
        apiVersion = "apps/v1";
        out = {
          name = "coredns";
          fqdn = "kube-dns.kube-system.svc.cluster.local";
        };
      };
      aliases = [ "dns" ];

      # Platform intents for CoreDNS. Materialized into CNPs and injected
      # as extraDeps on the import marker, establishing:
      # workload → platform-dns marker → CoreDNS CNPs → cilium enforcer.
      # Without these, Cilium `always` mode blocks CoreDNS traffic and the
      # cluster is non-functional.
      platformIntents = lib.mkIf config.networkPolicy.enable {
        coredns-egress = {
          namespace = "kube-system";
          podSelector = {
            "k8s-app" = "kube-dns";
          };
          egress = [
            { to = "apiserver"; }
            {
              to = "world";
              ports = [
                {
                  port = 53;
                  protocol = "UDP";
                }
                {
                  port = 53;
                  protocol = "TCP";
                }
                {
                  port = 443;
                  protocol = "TCP";
                }
              ];
            }
          ];
        };

        coredns-ingress = {
          namespace = "kube-system";
          podSelector = {
            "k8s-app" = "kube-dns";
          };
          ingress = [
            {
              from = "all-pods";
              ports = [
                {
                  port = 53;
                  protocol = "UDP";
                }
                {
                  port = 53;
                  protocol = "TCP";
                }
              ];
            }
          ];
        };
      };
    };

    platform-storage = {
      package = kix.mkImport {
        out = {
          storageClassName = "standard";
        };
      };
      aliases = [ "storageClasses" ];
      optional = true;
    };
  };

  # Platform intents — connectivity for kind's pre-installed system pods
  # that don't have an associated import instance. Intents for pods with
  # imports (CoreDNS) live on the import's `platformIntents` field instead,
  # so the import marker transitively depends on its CNPs.
  networkPolicy.platformIntents = lib.mkIf config.networkPolicy.enable {
    local-path-provisioner-egress = {
      scope = "clusterwide";
      targetNamespace = "local-path-storage";
      podSelector = {
        "app" = "local-path-provisioner";
      };
      egress = [
        { to = "apiserver"; }
        { to = "dns"; }
      ];
    };
  };
}
