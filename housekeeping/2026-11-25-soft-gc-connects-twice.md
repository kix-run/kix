# 2026-11-25 · `cli/kix-cli/src/commands/gc/mod.rs` · `kix gc` without `--full-scan` connects to the cluster twice.

`plan_record_retirement` in `gc/plan.rs` connects before the build, and `run_soft` connects again after it to run the binding check and delete. Each builds its own client and its own `Connection`. Passing the first client and connection through would remove the second connection and the second kubeconfig read.
