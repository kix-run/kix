# 2026-09-19 · `kix/packages/openebs` · The DiskPool CRD comes from the operator at runtime, so kix cannot order a DiskPool CR against it.

Mayastor ships no manifest for `diskpools.openebs.io`. The `operator-diskpool`
binary creates the CRD when it starts. A DiskPool custom resource in a cluster
definition can therefore only be ordered after that Deployment, which is what
`config.diskPools` now does.

That edge is weaker than a CRD edge. The Deployment being applied does not mean
the CRD is served yet, and kix refreshes its API discovery after applying the
CRDs it owns, so it may not know the kind when it applies the CR. Nothing in
the tree sets `config.diskPools`, so none of this has been tried.
