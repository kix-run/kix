# 2026-11-25 · `cli/kix-cli/src/commands/gc/mod.rs` · `kix gc` connects to the cluster twice, with or without `--full-scan`.

`open_records` in `gc/plan.rs` connects first to read the Active record (and, without `--full-scan`, to plan record retirement). `run_soft` and `run_hard_async` then connect again after loading the build, to run the binding check, sweep, and delete. Each builds its own client and its own `Connection`. Passing the first client and connection through would remove the second connection and the second kubeconfig read.
