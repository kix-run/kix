# clusters/test-zfs-localpv.nix: zfs-localpv on a kind cluster, with the
# snapshot controller that its VolumeSnapshotClass needs.
#
# kind nodes have no ZFS pool. The node plugin starts and registers with the
# kubelet, but it cannot create a dataset, so this cluster judges the
# controller's ZFSVolume records, the registration, and the classes.
#
# Build:  kix build zfs-localpv

{ kix, packages }:

kix.buildCluster {
  name = "zfs-localpv";
  modules = [
    kix.flavors.kind

    {
      namespaces.storage = { };

      instances.storage = {
        snapshot-controller.package = packages.experimental.snapshot-controller;
        zfs-localpv = {
          package = packages.experimental.zfs-localpv;
          config = {
            storageClasses.zfs.parameters.poolname = "zfspv-pool";
            volumeSnapshotClasses.zfs = { };
          };
        };
      };
    }
  ];
}
