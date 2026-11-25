+++
kind = "added"
packages = ["experimental/tempo"]
+++
`packages.experimental.tempo` can now authenticate to an external S3 bucket with an AWS IAM role instead of S3 access keys. On clusters using `kix.flavors.eks` or `kix.modules.experimental.irsa-webhook`, set `deps.storageCredentials = kix.cloudIdentity.aws { roleArn = "..."; };` alongside `config.objectStorage.bucket` and `config.settings.storage.trace.s3.endpoint`. Kix configures the identity on Tempo's ServiceAccount, restarts the pod when the role changes, and leaves AWS key variables unset so Tempo authenticates with the role. Evaluation fails if you pass a cloud identity when `objectStorage` is unset, when `deps.endpointService` points to an in-cluster S3 service, when `objectStorage.credentialKeys` is set, or when `env` sets `AWS_ACCESS_KEY_ID`, `AWS_ACCESS_KEY`, `AWS_SECRET_ACCESS_KEY`, `AWS_SECRET_KEY`, or `AWS_SESSION_TOKEN`.
