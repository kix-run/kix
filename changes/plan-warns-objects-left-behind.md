+++
kind = "added"
+++
With `--prune`, `kix plan` and `kix deploy` now warn when the new build no
longer declares a CustomResourceDefinition (through `scope.mkCRD`,
`scope.mkCRDRef`, or `kix.mkImport`), while custom resources of that kind remain
on the cluster and will not be deleted by the prune (such as a Certificate
created with `kubectl`). Kix still allows the deploy; to clean those objects up
while their controller is still running, delete them before deploying with
`--prune`. The warning lists up to 20 objects, those with finalizers first,
because once the kind's controller is removed, nothing clears their finalizers
or cleans up external resources they manage. In the `Plan` document, the prune
entry for the CustomResourceDefinition or CRD reference now lists them under
`left_behind`.
