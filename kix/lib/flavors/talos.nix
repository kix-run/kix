# Flavor: Talos — immutable, API-driven Kubernetes OS.
#
# No SSH, no shell, no package manager. All OS config is declarative via
# machineconfig YAML applied through talosctl. Kernel modules (NVIDIA, etc.)
# require custom system extensions baked at image build time.
#
# Ships Flannel by default — cni is environment-owned (exclusive). When
# replacing it with Cilium (common in production: `cni.name = "none"` in
# the machineconfig), override `cluster.roles.cni.binding = "absent"` and
# add a managed CNI instance. No default StorageClass or LoadBalancer.
#
# Platform imports: DNS (coredns, bundled). No default storage.

{ lib, kix, ... }:
{
  cluster.provider = lib.mkDefault "talos";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "flannel";
    };
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
