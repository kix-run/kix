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
let
  platformDns = import ./platform-dns.nix {
    inherit lib kix;
    inherit (config) clusterDomain;
  };
in
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
    platform-dns = platformDns {
      name = "kube-dns";
      namespace = "kube-system";
    };
  };
}
