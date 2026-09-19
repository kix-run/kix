# 2026-09-19 · `cli/kix/src/cluster/` · Prune deletes an orphaned CRD like any resource, and an apply does not check the live `status.storedVersions` first.

Deleting a CRD deletes every CR of that kind cluster-wide, and the
apiserver rejects a CRD apply that drops a version still stored, with a
message that does not say how to migrate. Neither case is special in
`scheduler.rs` or `apply.rs`, and `kix diff` does not surface either. Doc
146 §5.6 has the two guards.
