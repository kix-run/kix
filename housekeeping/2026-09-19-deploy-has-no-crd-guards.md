# 2026-09-19 · `cli/kix/src/cluster/` · Prune deletes an orphaned CRD like any resource, and an apply does not check the live `status.storedVersions` first.

Deleting a CRD deletes every CR of that kind cluster-wide, and the
apiserver rejects a CRD apply that drops a version still stored, with a
message that does not say how to migrate. Neither case is special in
`scheduler.rs` or `apply.rs`, and `kix diff` does not surface either. Doc
146 §5.6 has the two guards.
- Narrowed 2026-09-20: prune never deletes a CRD now, the way it never deletes a Namespace, and an apply rejected on `status.storedVersions` is reported as an error naming the migration rather than as a raw apiserver validation failure. `kix diff` still does not surface either case ahead of the deploy, which is the remaining half of doc 146 §5.6; the destructive one cannot happen any more.
