# 2026-11-27 · `cli/kix/src/cluster/inventory.rs` · The prune line for a kept shared object prints its resource id twice.

The plan prints `= ClusterRole.rbac.authorization.k8s.io/sweep-test-reader kept ClusterRole.rbac.authorization.k8s.io/sweep-test-reader, still deployed by Kix cluster sweep-b`. The renderer prints the resource in its own column, and `SharedOrphan::describe` starts its text with `kept <resource>` again.
