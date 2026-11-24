# 2026-11-24 · `cli/kix-cli/src/commands/deploy_log.rs` · The line-format deploy log prints `still on the cluster` and `ready` for objects `kix deploy --prune` deletes.

A reader cannot tell from the per-object lines whether Kix deleted an object
or kept it, because `prune_lines` uses one per-object message for both cases.
With `kix deploy --prune`, `LineObserver` prints `prune> deleting 8 object(s)
that left the build` and then `<object>> left the build, still on the cluster`
for each object it deletes, the same per-object text it prints without
`--prune` when it keeps the objects. Later `LineObserver` prints `<object>>
ready` for each deleted object.
