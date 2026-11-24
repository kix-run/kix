+++
kind = "added"
packages = ["experimental/tempo"]
+++
`tempo` can write trace blocks to an Amazon S3 bucket as an AWS IAM role instead of with access keys. Set `deps.storageCredentials = kix.cloudIdentity.aws { roleArn = "..."; }` on a cluster that runs the `eks` flavor or the `irsa-webhook` module. Kix puts the role on Tempo's ServiceAccount and sets no keys, so Tempo uses the role. Kix refuses the role with an in-cluster store, without `objectStorage`, with `objectStorage.credentialKeys`, or with an AWS key variable in `env`.
