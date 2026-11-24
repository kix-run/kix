+++
kind = "fixed"
packages = ["experimental/mayastor"]
+++
If your `mayastor` configuration sets `key = ""` with `operator = "Equal"` in `ioEngine.tolerations` or `csiNode.tolerations`, set a non-empty `key` or set `operator = "Exists"`. Kubernetes rejects an empty `key` unless `operator` is `"Exists"`, so a cluster with that setting previously built and then failed during deploy. `mayastor` now stops the build and names the invalid entry, as it already did when `key` was unset.
