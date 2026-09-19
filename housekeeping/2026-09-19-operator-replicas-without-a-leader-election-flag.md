# 2026-09-19 · `kix/packages/{prometheus-operator,kubevirt,cdi,arc,reloader}` · Several operator packages grant or omit leader election RBAC without ever passing the flag that turns it on.

Nothing in these packages says whether a second replica is safe, so the
availability mapping had to be guessed per package. `prometheus-operator`
grants a `coordination.k8s.io/leases` role scoped to the lease name
`prometheus-operator` (`kix/packages/prometheus-operator/operator.nix`,
the `operatorLeaderElection` role set) but the container args built a few
lines below never enable leader election. `arc`, `cdi`, `reloader` and
`event-logger` grant no lease RBAC at all, which is why they now declare
`meta.availability.max = "pod"`.

The cost is that a cluster asking for availability `node` may get two
replicas of a controller that cannot coordinate, and each one reconciles
everything. Worth one pass per package: confirm the flag, then either
pass it or record the ceiling.

- Corrected 2026-09-19: `cdi` now grants `coordination.k8s.io/leases` in its namespace `Role`, copied from upstream. Its `meta.availability.max = "pod"` still stands, because the operator takes only a helper lease and a second replica would still fight the first.
