# Flavor: ovh — OVHcloud Managed Kubernetes Service (MKS).
#
# Managed control plane. Node pools (multi-node capable). Default CNI is Canal
# (Flannel for pod networking + Calico for NetworkPolicy enforcement). Block
# storage via the OpenStack Cinder CSI driver (several `csi-cinder-*`
# StorageClasses; `csi-cinder-high-speed` is the cluster default). OVH Load
# Balancer is available for Services of type=LoadBalancer (a paid add-on).
#
# Platform imports: DNS (coredns, bundled), storage (csi-cinder-high-speed).
#
# Note: this flavor describes what an OVH MKS cluster *provides*. A minimal
# single-node deployment that deliberately avoids the paid LB / block storage
# (e.g. hostPath volumes + NodePort + a Cloudflare tunnel) expresses those as
# per-cluster overrides on top of this flavor, not here.

{ lib, kix, ... }:
{
  cluster.provider = lib.mkDefault "ovh";

  cluster.capabilities = {
    multiNode = lib.mkDefault true; # node pools
    managedControlPlane = lib.mkDefault true; # OVH runs the control plane
    nodeAutoscaling = lib.mkDefault false; # available per node-pool, off by default
    loadBalancer = lib.mkDefault true; # OVH Load Balancer (paid add-on)
    cni = lib.mkDefault "canal";
    networkPolicyAPI = lib.mkDefault "calico"; # Canal enforces via Calico
    persistentStorage = lib.mkDefault true; # Cinder CSI
    rwxStorage = lib.mkDefault false; # Cinder is RWO block storage
    volumeSnapshots = lib.mkDefault true; # Cinder CSI supports snapshots
    privilegedContainers = lib.mkDefault true; # MKS permits privileged / hostPath
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
      optional = true;
    };

    platform-storage = {
      package = kix.mkImport {
        out = {
          # OVH's default StorageClass. Override per-cluster for the other
          # csi-cinder-* classes, or for a hostPath/local-path provisioner on a
          # single-node minimal cluster.
          storageClassName = "csi-cinder-high-speed";
        };
      };
      aliases = [ "storageClasses" ];
      optional = true;
    };
  };
}
