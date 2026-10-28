# kind flavor for local development and CI.
#
# Stock kind installs `kindnet` CNI (exclusive), CoreDNS, and an ephemeral
# default StorageClass named `standard` (`local-path-provisioner`), with no
# LoadBalancer controller. When kind is created with `disableDefaultCNI = true`,
# set `cluster.roles.cni.binding = "absent"` to deploy a managed CNI such as
# Cilium.
#
# When `networkPolicy.enable = true`, this flavor declares platform network
# policy intents for CoreDNS and `local-path-provisioner` so Cilium's `always`
# enforcement mode does not block system pods.

{
  lib,
  kix,
  config,
  ...
}:
{
  cluster.provider = lib.mkDefault "kind";

  # Default `networking.podSubnet` in kind.
  cluster.network.podCidr = lib.mkDefault "10.244.0.0/16";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "kindnet";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "shadowable";
    loadBalancer.binding = lib.mkDefault "absent";
    snapshotController.binding = lib.mkDefault "absent";
    metricsApi.binding = lib.mkDefault "absent";
    registryMirror.binding = lib.mkDefault "absent";
  };

  # The kind node image enables `discard_unpacked_layers` in the v2 containerd
  # config table `[plugins."io.containerd.grpc.v1.cri".containerd]`. Set this
  # to false when `containerdConfigPatches` disables `discard_unpacked_layers`
  # in that same table.
  cluster.containerd.discardUnpackedLayers = lib.mkDefault true;

  cluster.capabilities = {
    multiNode = lib.mkDefault false;
    availabilityZones = lib.mkDefault [ ];
    managedControlPlane = lib.mkDefault false;
    nodeAutoscaling = lib.mkDefault false;
    privilegedContainers = lib.mkDefault true;
    daemonSets = lib.mkDefault true;
  };

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

      # Attach CoreDNS network policy intents to `platform-dns` so workloads
      # that depend on DNS are ordered after the CoreDNS policies and the
      # network policy enforcer.
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
          # Backed by the kind node container filesystem. Volumes do not survive
          # node container restarts.
          storageClassName = "standard";
          name = "standard";
        };
      };
    };
  };

  # Allow `local-path-provisioner` pods in `local-path-storage` to reach the
  # API server and DNS when network policy enforcement is enabled.
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
