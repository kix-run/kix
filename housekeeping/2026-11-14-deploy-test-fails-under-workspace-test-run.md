# 2026-11-14 · `cli/kix-cli/tests/deploy_test.rs` · Five deploy tests failed once during `cargo test --workspace`, and four later runs did not fail.

On branch `typed-output-modes`, one `cargo test -q --workspace` run failed `deploy_dry_run_shows_plan`, `plan_save_writes_the_plan_file`, `deploy_plan_refuses_json_and_a_changed_plan_file`, `deploy_reads_the_cache_under_the_cluster_name_not_the_attribute`, and `the_json_deploy_log_has_stdout_to_itself`, each on its first `.assert()`. The output of that run was cut off, so the exit code and stderr of the failed commands are not known. These tests run a real Nix evaluation of the example project from the repository root.

Four later runs passed, each with `--no-fail-fast` and the full log saved:

- Two full `cargo test --workspace` runs on main, and one more after a rebase.
- `cargo test -p kix-cli --test deploy_test` while one busy loop per CPU ran. It passed, and took 43.6 seconds instead of about 22.

Cargo runs test binaries one after another, never at the same time. So a workspace run gives `deploy_test` the same parallelism as running it alone, and other test binaries cannot run beside it. After a full run, `git status --ignored` showed no files left in the repository root.

The likely cause is outside the tests. During the failed run, other agents ran Nix and cargo on the same machine, and that run printed `SQLite database '.../eval-cache-v6/....sqlite' is busy`. Nix reported that error and went on. Contention on the shared Nix evaluation cache, or on the Nix store, may have made an evaluation fail.

To confirm it next time, keep the full log of a failing run, with the stderr of the `kix` commands. Then try to cause the failure: run `cargo test --workspace` in two worktrees at the same time, so that both evaluate with Nix together.
