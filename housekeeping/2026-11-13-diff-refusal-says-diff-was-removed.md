# 2026-11-13 · `cli/kix-cli/src/removed.rs` · The `kix diff` refusal says the command was removed, though `kix diff CLUSTER --from X` still works.

`DIFF_WITHOUT_BASELINE` (line 111) prints "[K3143] `kix diff CLUSTER` was removed...". A user reads that the command is gone. Suggested text: "[K3143] `kix diff` no longer compares with the live cluster. To compare with the cluster, run `kix plan CLUSTER --read-only`. To compare two builds, add `--from PATH`, `--from-bundle FILE`, or `--bundle FILE`."
