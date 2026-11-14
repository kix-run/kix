+++
kind = "fixed"
+++
`kix rollback` now runs the same dry-run checks and prints the same summary as `kix deploy` before changing the cluster. It stops before writing if a dry-run request fails without a response from the API server or if `--prune` cannot delete an orphaned object, and it lists any dependent objects the dry run could not reach. After the package changes, it shows refused writes and prune deletes, kept orphans, objects the dry run could not check, and the object write and delete counts. When nothing needs to change, `kix rollback` marks earlier failed deployment records as superseded instead of leaving them failed.

When you deploy a new build with `kix deploy --operator`, the operator now reruns any unchanged Job marked `kix.run/rerun` whose last run failed, matching `kix deploy`. `kix deploy --offline` connects to the cluster before reporting "Nothing to apply", so it checks live Jobs and marks earlier failed deployment records as superseded even when the build matches the local cache. In saved plan files (`kix plan --out`), an unreachable admission webhook uses the refusal reason `webhook_unreachable` instead of `other`.
