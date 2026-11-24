+++
kind = "added"
packages = ["experimental/stackgres-cluster"]
+++
`stackgres-cluster` takes a cloud identity for its backups in `deps.backupIdentity`, such as `kix.cloudIdentity.aws { roleArn = "..."; }`, when its `stackgres-object-storage` uses pod credentials. Kix writes the identity to `spec.metadata.annotations.serviceAccount` on the `SGCluster`, and the operator copies it to the `<cluster>-patroni` ServiceAccount that the database pods run as. Kix does not create those pods, so a changed identity does not restart them. Restart them with an `SGDbOps` with `op: restart`. Instances without `deps.backupIdentity` need no changes.
