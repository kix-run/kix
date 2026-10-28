# kubeadm flavor for upstream Kubernetes clusters.
#
# kubeadm installs only the control plane and CoreDNS. CNI, storage, load
# balancing, and metrics-server are marked `absent` so managed instances can
# provide them.

{
  config,
  lib,
  kix,
  ...
}:
{
  cluster.provider = lib.mkDefault "kubeadm";

  cluster.roles = {
    cni.binding = lib.mkDefault "absent";
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "absent";
    loadBalancer.binding = lib.mkDefault "absent";
    metricsApi.binding = lib.mkDefault "absent";
  };

  cluster.capabilities = {
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
      optional = true;
    };
  };
}
