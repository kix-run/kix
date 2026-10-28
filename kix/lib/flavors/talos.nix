# Talos Linux flavor.
#
# Talos ships Flannel CNI (exclusive) and CoreDNS by default, with no default
# StorageClass, LoadBalancer, or metrics-server. When `cni.name = "none"` is set
# in the Talos machine configuration, override `cluster.roles.cni.binding =
# "absent"` to deploy a managed CNI such as Cilium.

{
  config,
  lib,
  kix,
  ...
}:
{
  cluster.provider = lib.mkDefault "talos";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "flannel";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "absent";
    loadBalancer.binding = lib.mkDefault "absent";
    metricsApi.binding = lib.mkDefault "absent";
  };

  # Talos stores CRI registry hosts under `/etc/cri/conf.d/hosts` and enables
  # `discard_unpacked_layers` by default. Set `discardUnpackedLayers = false`
  # when the machine config disables `discard_unpacked_layers` in
  # `/etc/cri/conf.d/20-customization.part`.
  cluster.containerd = {
    registryConfigPath = lib.mkDefault "/etc/cri/conf.d/hosts";
    discardUnpackedLayers = lib.mkDefault true;
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
