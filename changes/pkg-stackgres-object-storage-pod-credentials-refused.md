+++
kind = "error"
packages = ["experimental/stackgres-object-storage"]
id = "K5962"
+++
`stackgres-object-storage` refuses `useIAMRole` or `fetchCredentialsFromMetadataService` set to true in `extraSpec` while `deps.storageCredentials` is also set, because StackGres uses only one of them. It also refuses either field on a type StackGres does not read it for (`s3Compatible`, `azureBlob`, or the other field's type), where it had no effect. To use pod credentials, remove `deps.storageCredentials` (or the `storageCredentials` alias on the Secret instance) and set `deps.backupIdentity` on each `stackgres-cluster`. To keep the Secret, remove the field.
