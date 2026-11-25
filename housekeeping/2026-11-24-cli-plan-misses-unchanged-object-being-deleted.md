# 2026-11-24 · `cli/kix/src/plan/planner.rs` · `kix deploy` skips an unchanged object that is being deleted, so it disappears after a successful deploy.

The command-line plan compares builds and never reads the live objects it
skips. An object that is unchanged in the build and has a
`deletionTimestamp` on the cluster is a Skip node, so the deploy neither
waits for it nor creates it again, and `kix plan` does not list it under
`being_deleted`. Only a changed object, `--reconcile`, or the operator
(`detect_changes_live` in `cli/kix/src/cluster/apply/mod.rs`) catches it.
`kix status` reports the object as not ready.
