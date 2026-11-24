+++
kind = "added"
packages = ["experimental/mayastor", "experimental/zfs-localpv"]
library = ["scope.mkCRD", "scope.mkCRDRef", "kix.types.toleration", "kix.tolerations", "kix.types.volumeSnapshotClass", "kix.storage.snapshotClassProblems", "kix.storage.mkSnapshotClasses"]
+++
Valid `mayastor` and `zfs-localpv` configurations need no changes, and their built manifests do not change. Both packages now share new Kix library helpers for pod tolerations and `VolumeSnapshotClass` options, giving them the same validation messages. Package authors can use these helpers directly: `kix.types.toleration` with `kix.tolerations.problems` and `kix.tolerations.render` for pod tolerations, and `kix.types.volumeSnapshotClass` with `kix.storage.snapshotClassProblems` and `kix.storage.mkSnapshotClasses` for CSI snapshot classes. `scope.mkCRD` and `scope.mkCRDRef` also accept `crRequires`, a list of resources that every custom resource of that kind waits for before `kix deploy` applies it, such as a Job that checks whether an admission webhook is ready.
