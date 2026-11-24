# 2026-11-24 · `cli/kix/src/cluster/ops/dry_run.rs` · `kix plan` does not check the new manifest of an object that is being deleted.

`apply_resource` refuses to apply onto an object with a `deletionTimestamp`
before it sends the dry-run patch, and `DryRun::apply` records a recreate
with no result. Schema errors, admission denials, and RBAC refusals for that
object therefore show up only when the real deploy creates it, after the
wait. The plan does not list the object under `not_checked` either.
