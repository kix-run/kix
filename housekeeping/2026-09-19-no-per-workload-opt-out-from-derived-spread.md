# 2026-09-19 · `kix/lib/plugins/spread` · A package cannot opt one workload out of derived spread without a trick, and the trick leaves the PDB behind.

A package with several Deployments gets constraints and a PDB on each one
with more than one replica. To exempt one of them the author has to set
`topologySpreadConstraints = [ ]` on that template, which is not
documented, and the PDB is still derived because `instanceProcessors.spread`
only checks replicas. `meta.spread = false` is the only other route and it
covers the whole package. Verified on a three-Deployment package on a
three-zone test cluster: the empty list removed the constraints and the
PDB stayed.
