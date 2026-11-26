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
or cleans up external resources they manage. Kix excludes objects owned through
`ownerReferences` by an object that the prune deletes, because Kubernetes
deletes them with their owner. In the `Plan` document, the prune entry for the
CustomResourceDefinition or CRD reference now lists them under `left_behind`.
After pruning, `kix deploy` and `kix rollback` warn about any remaining objects
after the summary, and include them under `left_behind` in the
`--log-format json` `summary` line. `kix plan --read-only -o json`, which
cannot take `--prune`, carries the same `left_behind` on its prune entries,
so a CI job with read-only credentials sees what a prune would leave.
