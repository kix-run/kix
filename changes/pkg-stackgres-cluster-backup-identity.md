+++
kind = "added"
packages = ["experimental/stackgres-cluster"]
+++
Existing clusters need no changes. `stackgres-cluster` (`packages.experimental.stackgres-cluster`) now accepts a cloud identity for backups in `deps.backupIdentity`, such as `kix.cloudIdentity.aws { roleArn = "..."; }`, when its `stackgres-object-storage` instance uses pod credentials. Kix writes the identity to `spec.metadata.annotations.serviceAccount` on the `SGCluster`, and the StackGres operator copies it to the `<cluster>-patroni` ServiceAccount used by the database pods. Because the operator creates those pods, deploying a change to `deps.backupIdentity` does not restart them. Create an `SGDbOps` resource with `op: restart` so running pods pick up the new credentials.
