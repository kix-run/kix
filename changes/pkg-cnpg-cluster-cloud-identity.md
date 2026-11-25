+++
kind = "added"
packages = ["cnpg-cluster"]
+++
`cnpg-cluster` can now authenticate S3 backups with an AWS IAM role as well as
a Secret. Existing instances that pass a Secret in `deps.storageCredentials`
need no changes. To use an IAM role, set
`deps.storageCredentials = kix.cloudIdentity.aws { roleArn = "..."; }`. Kix
sets `s3Credentials.inheritFromIAMRole` on the `ObjectStore` and writes the
cloud identity annotations to `spec.serviceAccountTemplate` on the `Cluster`
for the `ServiceAccount` created by the CloudNativePG operator. Because the
operator creates the PostgreSQL pods, changing the role does not restart them
automatically. Run `kubectl cnpg restart <cluster>` after changing the role.
