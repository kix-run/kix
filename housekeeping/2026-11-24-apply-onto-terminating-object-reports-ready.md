# 2026-11-24 · `cli/kix/src/cluster/apply/ssa.rs` · `kix deploy` applies onto an object that is being deleted, then reports a ConfigMap or Secret as ready before it disappears.

Readiness polling now fails immediately when an object has a
`deletionTimestamp`, so a terminating Deployment or custom resource fails the
deploy. Kinds that Kix counts as ready as soon as they exist (such as ConfigMap,
Secret, Service, and RBAC objects) skip readiness polling (`is_immediate_kind`
in `cli/kix/src/cluster/readiness/declared.rs`). For those kinds, server-side apply
succeeds against the terminating object, `kix deploy` reports it ready, and the
object disappears once its finalizers clear.

Waiting for the terminating object to disappear before creating its replacement,
and showing that replacement in the plan (doc 178 section 7), was built and then
moved out of the first pull request so the plan output and stateful-replacement
handling can be reviewed separately.
