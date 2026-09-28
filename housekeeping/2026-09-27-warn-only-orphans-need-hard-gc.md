# 2026-09-27 · `cli/kix-cli/src/commands/deploy.rs` · After a warn-only deploy, only `kix gc --hard` deletes the orphans it reported.

A default `kix deploy` prints `N orphaned (kept; pass --prune to delete)`
and then makes the new build the Active Activation and the local cache
entry (`~/.cache/kix/activations/<cluster>.path`). Running
`kix deploy --prune` next prints `activation identical to active ...
Nothing to apply.`, and soft `kix gc` diffs the cache against the same
build and prints `No garbage found.`. The orphans stay until someone runs
`kix gc --hard`, which neither message names. Seen on kind with a removed
ConfigMap and CR. The `--log-format line` text in `deploy_log.rs` says the same.
