+++
kind = "added"
library = ["scope.mkCRD", "scope.mkCRDRef", "kix.types.toleration", "kix.tolerations", "kix.types.volumeSnapshotClass", "kix.storage.snapshotClassProblems", "kix.storage.mkSnapshotClasses"]
+++
`scope.mkCRD` and `scope.mkCRDRef` take `crRequires`, a list of resources that every custom resource of the kind requires, such as a Job that checks the operator's admission webhook is serving. Packages with a toleration option can use `kix.types.toleration`, check it with `kix.tolerations.problems`, and render it with `kix.tolerations.render`. CSI driver packages can declare VolumeSnapshotClasses with `kix.types.volumeSnapshotClass`, check them with `kix.storage.snapshotClassProblems`, and build them with `kix.storage.mkSnapshotClasses`. `mayastor` and `zfs-localpv` now use these, so their messages about tolerations and VolumeSnapshotClasses have the same wording, and their manifests do not change.
