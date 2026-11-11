# 2026-11-11 · `kix rollback` · With `--yes` or in CI, rollback picks the newest Superseded record even when its build is not on this machine.

`commands/rollback.rs` takes `superseded[0]` without checking
`resolve_activation_by_hash`, which the interactive list already calls to mark
each entry `[store path missing]`. In CI this fails with "not found locally"
while an older record with a local build exists.
