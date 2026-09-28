# 2026-09-27 · `cli/kix/src/cluster/fetch.rs` · The managed-resource sweep returns every Kix cluster's objects, not only the named cluster's.

`sweep_managed` lists objects by `app.kubernetes.io/managed-by=kix` alone and
never filters on the `kix.run/cluster` label. `kix diff`, `kix status`,
`kix health`, `kix snapshot`, `kix gc --hard` and drift detection read that
sweep, so in a Kubernetes cluster that hosts two Kix clusters each command
reports the other cluster's objects as its own. `kix diff` counts them as
removals. `kix deploy` also rebuilds the previous state from the sweep
(`reconstruct_old_from_live` in `cli/kix-cli/src/commands/deploy.rs`) when the
active Activation's store path is missing or will not load, and on that path
it plans the other cluster's objects as orphans, which `--prune` deletes.
The Activation readers in `cli/kix/src/cluster/activation.rs` do filter on
the cluster label. The gc guide warns about this for hard mode only
(`garbage-collect-stale-resources.mdx`).
