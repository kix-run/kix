# 2026-11-04 · `cli/kix-cli/src/commands/diff.rs` · `kix diff` checks drift only on the machine that ran the last deploy.

`deployed_build` reads the Activation record's `kix.run/built-via` annotation, which is a local store path, and gives up when `kix-packages.json` is not there. Every other machine gets `drift: not_checked: deployed_build_unavailable`. The drift verdict itself needs no build: `drift::check_object` works from the live object's applied hash and `managedFields` alone.
