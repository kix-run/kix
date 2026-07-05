# Flavor: Lithus — RKE2 + external Cilium + OpenEBS (LocalPV-ZFS + Mayastor).
#
# Extends rke2.nix with the Lithus-specific cluster shape: Cilium for both
# CNI and NetworkPolicy enforcement, OpenEBS for both block (LocalPV-ZFS)
# and replicated NVMe-oF (Mayastor) storage. Storage is shipped verbatim
# from this flavor — every Lithus cluster gets the same StorageClasses,
# StorageProfiles, DiskPools, VolumeSnapshotClasses, and the mayastor
# CSIDriver.
#
# DiskPool node names + disk path are read from `globals.<cluster>` so
# the flavor itself stays cluster-shape-agnostic. Pass them in via
# `cluster.flavor.lithus.{workers,mayastorDiskPath}`.
#
# Usage:
#   modules = [
#     kix.flavors.lithus
#     {
#       cluster.flavor.lithus.workers = globals.nw1.workers;
#       cluster.flavor.lithus.mayastorDiskPath = globals.nw1.mayastorDiskPath;
#     }
#   ];

{
  config,
  lib,
  kix,
  ...
}:

let
  inherit (lib) mkDefault mkOption types;

  # Inline package: emits a list of raw resources (each given as
  # `{ apiVersion, kind, name, ?namespace, spec/extra }`) through
  # scope.mkResource / mkClusterResource. Same pattern as
  # nw1/storage-stubs.nix — copy here so flavors stay self-contained.
  mkRawResources = description: resources: {
    meta = {
      version = "lithus-flavor";
      inherit description;
    };

    build =
      { scope, ... }:
      let
        built = builtins.listToAttrs (
          map (r: {
            name = "${r.kind}-${r.name}";
            value =
              let
                args = removeAttrs r [ "clusterScoped" ];
                fn = if (r.clusterScoped or false) then scope.mkClusterResource else scope.mkResource;
              in
              fn args;
          }) resources
        );
        firstKey = builtins.head (builtins.attrNames built);
        rest = builtins.attrValues (builtins.removeAttrs built [ firstKey ]);
      in
      built
      // {
        root = built.${firstKey} // {
          requires = (built.${firstKey}.requires or [ ]) ++ rest;
        };
      };
  };

  # Resource recipes ----------------------------------------------------

  storageClasses = [
    {
      apiVersion = "storage.k8s.io/v1";
      kind = "StorageClass";
      name = "lbs1-pool1-2x";
      clusterScoped = true;
      annotations."storageclass.kubernetes.io/is-default-class" = "true";
      extra = {
        provisioner = "io.openebs.csi-mayastor";
        parameters = {
          fsType = "xfs";
          repl = "2";
          protocol = "nvmf";
          ioTimeout = "300";
          local = "true";
          thin = "true";
        };
        volumeBindingMode = "Immediate";
        reclaimPolicy = "Delete";
        allowVolumeExpansion = true;
      };
    }
    {
      apiVersion = "storage.k8s.io/v1";
      kind = "StorageClass";
      name = "localzfs";
      clusterScoped = true;
      annotations = {
        "storageclass.kubernetes.io/is-default-class" = "false";
        "storageclass.kubevirt.io/is-default-virt-class" = "false";
      };
      extra = {
        provisioner = "zfs.csi.openebs.io";
        parameters = {
          recordsize = "128k";
          compression = "on";
          dedup = "off";
          fstype = "zfs";
          poolname = "zfspool0";
        };
        volumeBindingMode = "WaitForFirstConsumer";
        reclaimPolicy = "Delete";
        allowVolumeExpansion = true;
      };
    }
    {
      apiVersion = "storage.k8s.io/v1";
      kind = "StorageClass";
      name = "localzfs-retain";
      clusterScoped = true;
      annotations = {
        "storageclass.kubernetes.io/is-default-class" = "false";
        "storageclass.kubevirt.io/is-default-virt-class" = "false";
      };
      extra = {
        provisioner = "zfs.csi.openebs.io";
        parameters = {
          recordsize = "128k";
          compression = "on";
          dedup = "off";
          fstype = "zfs";
          poolname = "zfspool0";
        };
        volumeBindingMode = "WaitForFirstConsumer";
        reclaimPolicy = "Retain";
        allowVolumeExpansion = true;
      };
    }
    {
      apiVersion = "storage.k8s.io/v1";
      kind = "StorageClass";
      name = "localzfs-block";
      clusterScoped = true;
      annotations = {
        "storageclass.kubernetes.io/is-default-class" = "false";
        "storageclass.kubevirt.io/is-default-virt-class" = "true";
      };
      extra = {
        provisioner = "zfs.csi.openebs.io";
        parameters.poolname = "zfspool0";
        volumeBindingMode = "WaitForFirstConsumer";
        reclaimPolicy = "Delete";
        allowVolumeExpansion = true;
      };
    }
  ];

  volumeSnapshotClasses = [
    {
      apiVersion = "snapshot.storage.k8s.io/v1";
      kind = "VolumeSnapshotClass";
      name = "csi-mayastor-snapshotclass";
      clusterScoped = true;
      annotations = {
        "snapshot.storage.kubernetes.io/is-default-class" = "true";
        "velero.io/csi-volumesnapshot-class" = "true";
      };
      extra = {
        driver = "io.openebs.csi-mayastor";
        deletionPolicy = "Delete";
      };
    }
    {
      apiVersion = "snapshot.storage.k8s.io/v1";
      kind = "VolumeSnapshotClass";
      name = "zfspv-snapclass";
      clusterScoped = true;
      annotations = {
        "snapshot.storage.kubernetes.io/is-default-class" = "true";
        "velero.io/csi-volumesnapshot-class" = "true";
      };
      extra = {
        driver = "zfs.csi.openebs.io";
        deletionPolicy = "Delete";
      };
    }
  ];

  csiDrivers = [
    {
      apiVersion = "storage.k8s.io/v1";
      kind = "CSIDriver";
      name = "io.openebs.csi-mayastor";
      clusterScoped = true;
      spec = {
        attachRequired = true;
        podInfoOnMount = true;
        storageCapacity = true;
        volumeLifecycleModes = [ "Persistent" ];
      };
    }
  ];

  # CDI StorageProfiles — one per StorageClass that backs CDI-managed PVCs.
  storageProfileNames = [
    "lbs1-pool1-2x"
    "openebs-hostpath"
    "localzfs"
    "localzfs-retain"
    "mayastor-etcd-localpv"
    "mayastor-loki-localpv"
  ];

  storageProfiles = map (n: {
    apiVersion = "cdi.kubevirt.io/v1beta1";
    kind = "StorageProfile";
    name = n;
    clusterScoped = true;
    spec = {
      claimPropertySets = [
        {
          accessModes = [ "ReadWriteOnce" ];
          volumeMode = "Filesystem";
        }
      ];
      cloneStrategy = if n == "lbs1-pool1-2x" then "csi-clone" else "copy";
    };
  }) storageProfileNames;

  workers = config.cluster.flavor.lithus.workers;
  diskPath = config.cluster.flavor.lithus.mayastorDiskPath;

  diskPools = map (worker: {
    apiVersion = "openebs.io/v1beta3";
    kind = "DiskPool";
    name = "${worker}-pool1";
    spec = {
      node = worker;
      disks = [ diskPath ];
    };
  }) workers;

in
{
  imports = [ ./rke2.nix ];

  options.cluster.flavor.lithus = {
    workers = mkOption {
      type = types.listOf types.str;
      description = "Worker node names — one DiskPool emitted per worker.";
    };
    mayastorDiskPath = mkOption {
      type = types.str;
      default = "/dev/mapper/vg0-mayastor0";
      description = "Block device path used by the Mayastor DiskPool on every worker.";
    };
  };

  config = {
    cluster.provider = lib.mkForce "lithus";

    # Overrides on top of rke2: this RKE2 is configured with external
    # Cilium instead of Canal (still environment-owned — kix does not
    # deploy the CNI here; the cilium-external package only emits the CRD
    # ref marker and claims the enforcer role, not cni). Storage is
    # provided by the OpenEBS stack this flavor ships.
    cluster.roles = {
      cni.provider = lib.mkForce "cilium (rke2-managed)";
      storageClasses.binding = lib.mkForce "shadowable";
      loadBalancer = {
        binding = lib.mkForce "shadowable";
        provider = lib.mkForce "cilium lb-ipam";
      };
    };

    # Storage resource bundles — one inline-package instance per kind so
    # the build output groups them sensibly under openebs-system / _cluster.
    instances._cluster = {
      lithus-storage-classes = {
        package = mkRawResources "Lithus StorageClasses" storageClasses;
      };
      lithus-volume-snapshot-classes = {
        package = mkRawResources "Lithus VolumeSnapshotClasses" volumeSnapshotClasses;
      };
      lithus-csi-drivers = {
        package = mkRawResources "Lithus CSIDrivers" csiDrivers;
      };
      lithus-storage-profiles = {
        package = mkRawResources "Lithus StorageProfiles (CDI)" storageProfiles;
      };
    };

    instances.openebs-system = {
      lithus-disk-pools = {
        package = mkRawResources "Lithus per-worker DiskPools (Mayastor)" diskPools;
      };
    };

    # Default storageClass alias — exposes the cluster default
    # (lbs1-pool1-2x, mayastor) so packages depending on `storageClasses`
    # (persistent-volume-claim, stackgres-cluster, …) resolve via DI
    # without hardcoding. Pattern mirrors k3s flavor's platform-storage.
    instances.kube-system = {
      platform-storage = {
        package = kix.mkImport {
          roles = [ "storageClasses" ];
          out = {
            storageClassName = "lbs1-pool1-2x";
            rwx = true; # Mayastor NVMe-oF replicated volumes
            snapshots = true;
          };
        };
        optional = true;
      };
    };
  };
}
