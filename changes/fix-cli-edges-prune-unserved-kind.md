+++
kind = "fixed"
+++
`kix deploy --prune`, `kix rollback --prune`, `kix gc`, and the Kix operator now treat an orphan resource as already gone when the Kubernetes cluster has no API for its kind, since no object of that kind can exist on the cluster. Previously, pruning failed with "this Kubernetes cluster does not serve resource kind", held back the resource's dependencies, and kept the resource on the prune list, blocking every later `--prune` and `kix gc` run. This happened when a CustomResourceDefinition was deleted, or when a failed deploy recorded a custom resource whose CRD was never installed. Kix re-checks API discovery for the resource's group before treating it as gone, and still fails the delete if an aggregated API server does not respond, since its objects may still exist.
