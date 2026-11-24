+++
kind = "added"
packages = ["experimental/stackgres-object-storage"]
+++
`stackgres-object-storage` can now back up without a Secret by using the database pods' own cloud credentials. Set `extraSpec.s3.awsCredentials.useIAMRole = true` for `s3`, or `extraSpec.gcs.gcpCredentials.fetchCredentialsFromMetadataService = true` for `gcs`, and leave `deps.storageCredentials` unset. Kix then writes no secret key selectors and publishes the cloud as `out.ambientCloud`, so each `stackgres-cluster` that backs up there can take a cloud identity in `deps.backupIdentity`. Instances that read a Secret need no changes.
