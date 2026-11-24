+++
kind = "added"
packages = ["experimental/cert-manager"]
+++
Existing `cert-manager` instances need no changes: without `deps.controllerIdentity`, the controller continues to use the node's credentials. Pass a cloud identity (`kix.cloudIdentity.aws`, `kix.cloudIdentity.gcp`, or `kix.cloudIdentity.azure`, such as `kix.cloudIdentity.aws { roleArn = "..."; }`) to `deps.controllerIdentity` on `packages.experimental.cert-manager` to let Route 53, Cloud DNS, and Azure DNS solvers without static keys authenticate through the controller's ServiceAccount. Kix writes the required annotations on the controller's ServiceAccount, adds the Azure Workload Identity pod label on AKS, and restarts the controller pod when the identity changes. `deps.controllerIdentity` rejects Secrets; pass static DNS keys to `deps.issuerCredentials` on the `cluster-issuer` instance instead.
