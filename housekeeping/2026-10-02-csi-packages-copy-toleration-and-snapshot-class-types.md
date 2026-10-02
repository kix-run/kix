# 2026-10-02 · `kix/packages/{mayastor,zfs-localpv}` · Each CSI driver package defines its own toleration submodule and VolumeSnapshotClass option, build, and checks.

`kix/packages/mayastor/default.nix` (`tolerationType`, `snapshotClassType`,
the `snapshotClasses` part, and the toleration, default-class, reserved-name,
and missing-snapshot-API assertions) repeats what
`kix/packages/zfs-localpv/default.nix` defines. The two copies already differ in their message
text and option paths, and the next driver package will make a third.
`kix.storage.mkClasses` and `kix.types.storageClass` show the shape a shared
`kix.types.toleration` and snapshot-class helper could take.
