# 2026-11-10 · `cli/kix-cli/tests/select_test.rs` · `self_update_installs_the_newest_release_and_moves_the_link` failed once in a full `cargo test --workspace` run and passed on every rerun.

The panic was the `assert!(out.status.success())` in `stdout_of` (line 83), so a `kix` subprocess exited non-zero. The run was on the `kix-core` branch, which does not touch selection or release code. A flaky test here will fail CI at random.
