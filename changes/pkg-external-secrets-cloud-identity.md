+++
kind = "added"
packages = ["experimental/external-secrets"]
+++
`external-secrets` takes a cloud identity for its controller in the new optional dependency `controllerCredentials`, such as `deps.controllerCredentials = kix.cloudIdentity.aws { roleArn = "..."; }` (or `kix.cloudIdentity.gcp`, `kix.cloudIdentity.azure`). Kix writes the identity on the controller's ServiceAccount and restarts the controller pods when it changes. A SecretStore or ClusterSecretStore that names no credentials calls the cloud as this identity: AWS and Google Cloud stores set no `auth`, and Azure stores set `authType: WorkloadIdentity` without `serviceAccountRef`. The dependency does not accept a Secret instance. Static keys still go in a store's `auth.secretRef`.
