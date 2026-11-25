+++
kind = "changed"
cli = ["kix gc --full-scan"]
+++
`kix gc --full-scan` and the operator no longer treat an object that names no deployment record as belonging to the Kix cluster they work on, even when no other Kix cluster has records on the Kubernetes cluster. Before, once another Kix cluster's records were deleted, a full scan could delete that cluster's objects. These objects are now listed under "No deployment record on this cluster" and kept. This also covers this cluster's own leftovers whose records gc has retired. Pass `--include unattributed` to check them against the build and delete those that are not in it.
