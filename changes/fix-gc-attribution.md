+++
kind = "changed"
cli = ["kix gc --full-scan"]
+++
Pass `--include unattributed` to `kix gc --full-scan` to delete stale Kix-labeled objects that have no matching deployment record on the cluster, including old objects from this cluster whose records `kix gc` has retired. With `--include unattributed`, `kix gc --full-scan` checks those objects against the active deployment's build and deletes any not in it. By default, `kix gc --full-scan` now lists them under "No deployment record on this cluster" and keeps them, and the Kix operator leaves them alone, even when no other Kix cluster has records on the Kubernetes cluster. Previously, once another Kix cluster's deployment records were deleted, `kix gc --full-scan` or the Kix operator could treat that cluster's remaining objects as its own and delete them.
