# kind flavor for local development and CI.
#
# Pre-installs kindnet CNI and a local, ephemeral StorageClass `standard`
# (local-path-provisioner, annotated as the default; the node image's
# manifest is pkg/build/nodeimage/const_storage.go in kubernetes-sigs/kind),
# whose volumes do not survive container restarts. No LoadBalancer support.
#
# Role bindings (v2_discussions/127): kindnet owns the pod network
# exclusively. Deploying a managed CNI on stock kind breaks the cluster,
# so it is refused at eval. A kind cluster created with the default CNI
# disabled overrides `cluster.roles.cni.binding = "absent"` and fills the
# role with a managed instance (this is what ludo-kind does with cilium).
# DNS and storage are weak (shadowable) environment defaults, declared as
# platform imports below.
#
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

  # kind's default networking.podSubnet.
  cluster.network.podCidr = lib.mkDefault "10.244.0.0/16";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "kindnet";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "shadowable";
    loadBalancer.binding = lib.mkDefault "absent";
    # kind ships no snapshot CRDs or controller; a snapshot-controller
    # instance provides them.
    snapshotController.binding = lib.mkDefault "absent";
    # kind ships no metrics-server; a metrics-server instance provides
    # metrics.k8s.io.
    metricsApi.binding = lib.mkDefault "absent";
  };

  cluster.capabilities = {
    multiNode = lib.mkDefault false;
    availabilityZones = lib.mkDefault [ ];
    managedControlPlane = lib.mkDefault false;
    nodeAutoscaling = lib.mkDefault false;
    privilegedContainers = lib.mkDefault true;
    daemonSets = lib.mkDefault true;
  };

  # Platform-provided imports.
  instances.kube-system = {
    platform-dns = {
      package = kix.mkImport {
        kind = "Deployment";
        apiVersion = "apps/v1";
        roles = [ "dns" ];
        out = {
          name = "coredns";
          fqdn = "kube-dns.kube-system.svc.${config.clusterDomain}";
        };
      };

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
        kind = "StorageClass";
        apiVersion = "storage.k8s.io/v1";
        roles = [ "storageClasses" ];
        out = {
          # Ephemeral: backed by the docker container FS, does not survive
          # container restarts.
          storageClassName = "standard";
          name = "standard";
        };
      };
    };
  };

  # Connectivity for kind's pre-installed system pods
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
