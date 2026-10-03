# 2026-10-03 · `cli/kix-cli/src/commands/diff.rs` · `kix diff` treats every absent Job with a TTL as reaped, including failed Jobs and Jobs deleted before they finished.

`reaped_since_deploy` adds a build Job back to the old side when it declares its own deletion (`ttlSecondsAfterFinished` or a `hook-succeeded` delete policy), is absent live, and has the hash it had in the deployed build. Absence is the only evidence. A Job that failed and was removed by its TTL, or that someone deleted while it ran, also reads as unchanged, so `kix diff` does not say the Job never completed.
