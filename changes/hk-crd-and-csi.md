+++
kind = "added"
packages = ["experimental/mayastor", "experimental/zfs-localpv"]
library = ["scope.mkCRD", "scope.mkCRDRef", "kix.types.toleration", "kix.tolerations", "kix.types.volumeSnapshotClass", "kix.storage.snapshotClassProblems", "kix.storage.mkSnapshotClasses"]
+++
Package authors can now set `crRequires` on `scope.mkCRD` and `scope.mkCRDRef` so every custom resource of that kind waits for the listed resources, such as a Job that checks whether an operator's admission webhook is ready. Packages with pod toleration options can use `kix.types.toleration`, validate entries with `kix.tolerations.problems`, and format them for a pod spec with `kix.tolerations.render`. CSI driver packages can use `kix.types.volumeSnapshotClass` for `VolumeSnapshotClass` options, validate them with `kix.storage.snapshotClassProblems`, and build the resources with `kix.storage.mkSnapshotClasses`. `mayastor` and `zfs-localpv` now share these toleration and snapshot-class helpers, giving both packages the same validation messages. Their built manifests do not change.
