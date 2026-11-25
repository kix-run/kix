+++
kind = "added"
packages = ["experimental/stackgres-object-storage"]
+++
Instances that authenticate with a Secret alone need no changes. `stackgres-object-storage` (`packages.experimental.stackgres-object-storage`) can now use the database pods' cloud credentials instead of a Secret on AWS S3 and Google Cloud Storage. Set `extraSpec.s3.awsCredentials.useIAMRole = true` for `type = "s3"`, or `extraSpec.gcs.gcpCredentials.fetchCredentialsFromMetadataService = true` for `type = "gcs"`, and leave `deps.storageCredentials` unset. Kix then omits `secretKeySelectors` on the `SGObjectStorage` and sets `out.ambientCloud` to `"aws"` or `"gcp"`. Give each `stackgres-cluster` instance that backs up there a cloud identity in `deps.backupIdentity`, or leave `deps.backupIdentity` unset to use the node's credentials.
