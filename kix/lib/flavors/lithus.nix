# Flavor: Lithus — RKE2 + external Cilium + OpenEBS (LocalPV-ZFS + Mayastor).
#
# Decomposed per doc 127 §5 into:
#
#   - Target preset (this module's `config`): rke2 axioms + Lithus role
#     bindings. RKE2 here is configured with external Cilium instead of
#     Canal (still environment-owned — kix does not deploy the CNI; the
#     cilium-external package only emits the CRD ref marker and claims the
#     enforcer role, not cni).
#   - Stock catalog (`availablePackages.lithus-storage`): the OpenEBS
#     storage surface — StorageClasses, StorageProfiles, DiskPools,
#     VolumeSnapshotClasses, the mayastor CSIDriver — as ONE package that
#     claims the `storageClasses` role and is instantiated only when the
#     graph demands storage. A cluster with no PVC-bearing workload
#     compiles on lithus without OpenEBS in the artifact.
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
  ...
}:

let
  inherit (lib) mkOption types;

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

  # Stock catalog package: the whole OpenEBS storage surface as one
  # instance. Claims the `storageClasses` role, so it is pulled in by
  # auto-instantiation when the graph demands storage (weak role demand —
  # PVC-bearing packages take `storageClasses` as an optional dep) and
  # its out satisfies the role contract for consumers.
  lithusStorage = {
    meta = {
      version = "lithus-flavor";
      description = "Lithus OpenEBS storage stock — StorageClasses, StorageProfiles, DiskPools, VolumeSnapshotClasses, mayastor CSIDriver";
      roles = [ "storageClasses" ];
    };

    build =
      { scope, ... }:
      let
        allRecipes = storageClasses ++ volumeSnapshotClasses ++ csiDrivers ++ storageProfiles ++ diskPools;
        built = builtins.listToAttrs (
          map (r: {
            name = "${r.kind}-${r.name}";
            value =
              let
                args = removeAttrs r [ "clusterScoped" ];
                fn = if (r.clusterScoped or false) then scope.mkClusterResource else scope.mkResource;
              in
              fn args;
          }) allRecipes
        );
        firstKey = builtins.head (builtins.attrNames built);
        rest = builtins.attrValues (builtins.removeAttrs built [ firstKey ]);
      in
      built
      // {
        root = {
          resource = built.${firstKey};
          requires = rest;
          out = {
            storageClassName = "lbs1-pool1-2x";
          };
        };
      };
  };

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

    # Target-preset overrides on top of rke2. storageClasses inherits
    # rke2's "absent" binding: the role is vacant until the stock catalog
    # below fills it on demand.
    cluster.roles = {
      cni.provider = lib.mkForce "cilium (rke2-managed)";
      loadBalancer = {
        binding = lib.mkForce "shadowable";
        provider = lib.mkForce "cilium lb-ipam";
      };
    };

    # Stock catalog: on the shelf, instantiated only when demanded.
    availablePackages.lithus-storage = {
      package = lithusStorage;
      namespace = "openebs-system";
    };
  };
}
