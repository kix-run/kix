# kubeadm flavor for an upstream Kubernetes bootstrap.
#
# Ships nothing beyond the control plane. CNI, storage, and load balancing
# are bring-your-own: the roles are declared vacant ("absent"), so managed
# instances fill them and a consumer without a provider gets a link error
# at eval.
#
# Platform imports: DNS (coredns, bundled by kubeadm). No default storage.

{ lib, kix, ... }:
{
  cluster.provider = lib.mkDefault "kubeadm";

  cluster.roles = {
    cni.binding = lib.mkDefault "absent"; # must be installed separately
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "absent"; # no default StorageClass
    loadBalancer.binding = lib.mkDefault "absent";
  };

  cluster.capabilities = {
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
          fqdn = "kube-dns.kube-system.svc.cluster.local";
        };
      };
      optional = true;
    };
  };
}
