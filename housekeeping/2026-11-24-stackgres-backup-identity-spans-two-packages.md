# 2026-11-24 · `kix/packages/experimental/stackgres-object-storage` · A cloud role for StackGres backups cannot be given in one package.

StackGres runs wal-g inside the Patroni container of each cluster pod, so the role must sit on the ServiceAccount `<cluster>-patroni`, which the operator creates from the SGCluster's `spec.metadata.annotations.serviceAccount` (stackgres-cluster). The switch that tells wal-g to use that role (`s3.awsCredentials.useIAMRole`, `gcs.gcpCredentials.fetchCredentialsFromMetadataService`) sits on the SGObjectStorage (stackgres-object-storage), which several clusters can share. Until this is built, the package still sends users to `extraSpec` and still writes the Secret selectors.

Decided, not built: `v2_discussions/180_cloud_identity_across_packages.md` (build plan, step 3).
