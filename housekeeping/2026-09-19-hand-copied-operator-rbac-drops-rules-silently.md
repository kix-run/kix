# 2026-09-19 · `kix/packages/*` · RBAC hand-copied from an upstream operator manifest can drop whole roles, and nothing tells us.

The `cdi` package copied the upstream ClusterRole rule for rule but left
out the namespace `Role` and its `RoleBinding` entirely. The operator
still started, reported ready, and then did nothing at all. The only
sign was one line in its own log: `leases.coordination.k8s.io
"cdi-operator-leader-election-helper" is forbidden`. No kix check, no
build warning and no readiness probe saw it.

The cost is a deploy that looks healthy and is not, found only by
reading an operator's log. We have no way today to say "this package's
RBAC came from that upstream manifest" and check the two still agree, so
every hand-copied package can carry the same gap. A vendored upstream
YAML next to the package, plus a test that diffs the rendered roles
against it, would catch it.
