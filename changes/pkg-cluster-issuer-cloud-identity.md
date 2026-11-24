+++
kind = "added"
packages = ["experimental/cluster-issuer"]
+++
Existing `cluster-issuer` instances need no changes: solvers with static keys, and issuers paired with a `cert-manager` instance that sets no `deps.controllerIdentity`, build as before. When `cert-manager` sets `deps.controllerIdentity`, `packages.experimental.cluster-issuer` now checks every Route 53, Cloud DNS, and Azure DNS solver configured without static keys to make sure its cloud matches the controller's cloud identity. If the clouds differ, evaluation fails and names both the solver and the `cert-manager` instance. Passing a cloud identity in `deps.issuerCredentials` also fails evaluation and points you to `deps.controllerIdentity` on the `cert-manager` instance.
