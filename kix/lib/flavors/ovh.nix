# OVHcloud Managed Kubernetes Service (MKS) flavor.
#
# OVH MKS provides a managed control plane, Canal CNI (Flannel networking with
# Calico NetworkPolicy enforcement, exclusive), CoreDNS, OpenStack Cinder CSI
# block storage (`csi-cinder-high-speed` by default), and an optional paid OVH
# Load Balancer. Single-node or minimal clusters that avoid paid load balancers
# and block storage can override these bindings per cluster.

{
  config,
  lib,
  kix,
  ...
}:
let
  platformDns = import ./platform-dns.nix {
    inherit kix;
    inherit (config) clusterDomain;
  };
in
{
  cluster.provider = lib.mkDefault "ovh";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "canal";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "shadowable";
    loadBalancer = {
      binding = lib.mkDefault "shadowable";
      provider = lib.mkDefault "ovh-loadbalancer (paid add-on)";
    };
  };

  cluster.capabilities = {
    multiNode = lib.mkDefault true;
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault false; # available per node pool, off by default
    privilegedContainers = lib.mkDefault true;
    daemonSets = lib.mkDefault true;
  };

  instances.kube-system = {
    platform-dns = platformDns {
      name = "kube-dns";
      namespace = "kube-system";
    };

    platform-storage = {
      package = kix.mkImport {
        kind = "StorageClass";
        apiVersion = "storage.k8s.io/v1";
        roles = [ "storageClasses" ];
        out = {
          # Default StorageClass on OVH MKS. Override per cluster to use another
          # `csi-cinder-*` class or a local provisioner.
          storageClassName = "csi-cinder-high-speed";
          name = "csi-cinder-high-speed";
        };
      };
    };
  };
}
