+++
kind = "error"
packages = ["experimental/stackgres-object-storage"]
id = "K5962"
+++
If a `stackgres-object-storage` instance (`packages.experimental.stackgres-object-storage`) sets `useIAMRole = true` or `fetchCredentialsFromMetadataService = true` in `extraSpec` while `storageCredentials` is also bound, keep only one credential source. To use pod credentials, remove `deps.storageCredentials` (or remove the `storageCredentials` alias from the Secret instance in that namespace), and set `deps.backupIdentity` on each `stackgres-cluster` instance unless the pods use node credentials. To keep using the Secret, remove `useIAMRole` or `fetchCredentialsFromMetadataService` from `extraSpec`. Also remove either field if it is set on `s3Compatible`, `azureBlob`, or the wrong storage `type` (`useIAMRole` is only for `s3`, and `fetchCredentialsFromMetadataService` is only for `gcs`). Kix now rejects these configurations because StackGres uses only one credential source and does not support pod credentials on other storage types.
