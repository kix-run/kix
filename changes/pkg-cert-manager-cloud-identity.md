+++
kind = "added"
packages = ["experimental/cert-manager"]
+++
`cert-manager` accepts a cloud identity for its controller in `deps.controllerIdentity`, such as `kix.cloudIdentity.aws { roleArn = "..."; }`. Kix writes it on the controller's ServiceAccount, adds the Azure Workload ID pod label on AKS, and restarts the controller when the identity changes. DNS-01 solvers that set no key, on Route 53, Cloud DNS, or Azure DNS, then use it. A Secret in `deps.controllerIdentity` fails the build. Pass static keys to `deps.issuerCredentials` of a `cluster-issuer` instance instead. Without the dependency, the controller keeps using the node's credentials.
