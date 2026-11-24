+++
kind = "added"
packages = ["cnpg-cluster"]
+++
`cnpg-cluster` can back up to S3 as an AWS IAM role instead of with access
keys. Set `deps.storageCredentials = kix.cloudIdentity.aws { roleArn = "..."; }`.
The ObjectStore then sets `s3Credentials.inheritFromIAMRole`, and the
Cluster's `spec.serviceAccountTemplate` carries the role for the ServiceAccount
that the CloudNativePG operator creates. Kix does not restart the instance pods
when the role changes; run `kubectl cnpg restart <cluster>`. A Secret in
`storageCredentials` works as before.
