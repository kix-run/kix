+++
kind = "fixed"
+++
`kix deploy --prune`, `kix rollback --prune`, `kix gc`, and the Kix operator now count an object as already gone when the Kubernetes cluster does not serve its kind, because no object of that kind can exist. Previously each prune failed on it with "this Kubernetes cluster does not serve resource kind", kept what it depended on, and left it recorded for the next prune, so the cluster could never finish a prune or `kix gc`. This happened, for example, after a deploy that stopped before it created a custom resource whose CustomResourceDefinition was never installed. Before it decides, Kix asks the cluster again about the kind's API group. If an aggregated API does not answer, the prune still fails, because its objects may exist.
