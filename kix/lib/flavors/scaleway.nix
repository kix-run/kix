# Flavor: scaleway — Scaleway Kapsule (managed Kubernetes).
#
# Managed control plane (the shared/mutualized plane is free; `type = "kapsule"`
# on the cluster resource). Node pools (multi-node capable). Default CNI is
# Cilium (which also enforces NetworkPolicy via CiliumNetworkPolicy) —
# environment-owned, exclusive. Scaleway Load Balancer is available for
# Services of type=LoadBalancer (a paid add-on).
#
# Storage (verified against a live fr-par cluster):
#   - Block CSI `csi.scaleway.com`: classes scw-bssd / sbs-default / sbs-5k /
#     sbs-15k (+ *-retain variants). `sbs-default` is the cluster default.
#     RWO only. Preinstalled on every node.
#   - File Storage CSI `filestorage.csi.scaleway.com`: classes sfs-standard
#     (+ -retain), RWX (ReadWriteMany, NFS-backed). NOT preinstalled — enable by
#     tagging the cluster `scw-filestorage-csi`. CAVEAT: its filestorage-csi-node
#     DaemonSet has a nodeAffinity allow-list of instance types (BASIC3 / POP2 /
#     STANDARD2-3 / COMPUTE3 / MEMORY3 / GPU) that EXCLUDES the cheap DEV1 /
#     PLAY2 development range — on those nodes the driver never schedules and
#     sfs PVCs fail with "no topology key found on CSINode". So RWX is only
#     usable on a BASIC3+ node.
#
# Platform imports: DNS (coredns, bundled), storage (sbs-default).
#
# Note: like the other cloud flavors, this DESCRIBES what a Kapsule cluster
# provides — it does not provision one. In the Paperhound PoC the cluster itself
# is provisioned declaratively with Terranix (Terraform-via-Nix); this flavor is
# the KiX-side description that workloads deploy against.

{ lib, kix, ... }:
{
  cluster.provider = lib.mkDefault "scaleway";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "cilium (kapsule-managed)";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "shadowable";
    loadBalancer = {
      binding = lib.mkDefault "shadowable";
      provider = lib.mkDefault "scaleway-lb (paid add-on)";
    };
  };

  cluster.capabilities = {
    multiNode = lib.mkDefault true; # node pools
    managedControlPlane = lib.mkDefault true; # Scaleway runs the control plane
    nodeAutoscaling = lib.mkDefault false; # available per node-pool, off by default
    privilegedContainers = lib.mkDefault true; # Kapsule permits privileged / hostPath
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
          # Kapsule's default StorageClass. Override per-cluster for the other
          # block classes (scw-bssd, sbs-5k/15k, *-retain) or the File Storage
          # class (sfs-standard, RWX — needs a BASIC3+ node + the
          # scw-filestorage-csi cluster tag).
          storageClassName = "sbs-default";
        };
      };
      optional = true;
    };
  };
}
