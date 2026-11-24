+++
kind = "added"
packages = ["experimental/cluster-issuer"]
+++
`cluster-issuer` checks each Route 53, Cloud DNS, or Azure DNS solver that sets no key against the cloud identity of the `cert-manager` instance. The build fails when they name different clouds, and the error names the solver and the `cert-manager` instance. A cloud identity in `deps.issuerCredentials` fails the build and points to `deps.controllerIdentity` of the `cert-manager` instance. Solvers with keys, and `cert-manager` instances without a cloud identity, build as before.
