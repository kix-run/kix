# Flavor: ovh — OVHcloud Managed Kubernetes Service (MKS).
#
# Managed control plane. Node pools (multi-node capable). Default CNI is
# Canal (Flannel for pod networking + Calico for NetworkPolicy enforcement)
# — environment-owned, exclusive. Block storage via the OpenStack Cinder
# CSI driver (several `csi-cinder-*` StorageClasses; `csi-cinder-high-speed`
# is the cluster default). OVH Load Balancer is available for Services of
# type=LoadBalancer (a paid add-on).
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
    multiNode = lib.mkDefault true; # node pools
    managedControlPlane = lib.mkDefault true; # OVH runs the control plane
    nodeAutoscaling = lib.mkDefault false; # available per node-pool, off by default
    privilegedContainers = lib.mkDefault true; # MKS permits privileged / hostPath
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
          fqdn = "kube-dns.kube-system.svc.cluster.local";
        };
      };
      optional = true;
    };

    platform-storage = {
      package = kix.mkImport {
        roles = [ "storageClasses" ];
        out = {
          # OVH's default StorageClass. Override per-cluster for the other
          # csi-cinder-* classes, or for a hostPath/local-path provisioner on a
          # single-node minimal cluster.
          storageClassName = "csi-cinder-high-speed";
          rwx = false; # Cinder is RWO block storage
          snapshots = true; # Cinder CSI supports snapshots
        };
      };
      optional = true;
    };
  };
}
