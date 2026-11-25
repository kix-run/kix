# 2026-11-25 · `cli/kix/src/cluster/scheduler/mod.rs` · Deploy's prune prints "deleted" and counts "pruned" for an object that was never there.

`Pruned::Gone` and `Pruned::NotServed` both become `Pruning::Gone`, which emits
`Verdict::Ready`, and the log line for a delete node at `Ready` is `deleted`
(`deploy_log::delete_line`). An orphan a failed deploy recorded but never
created shows as deleted and adds to the `pruned` count. `kix gc` says
"already gone" for the same case.
