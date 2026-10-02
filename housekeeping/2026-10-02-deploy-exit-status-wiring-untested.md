# 2026-10-02 · `cli/kix-cli/src/commands/deploy.rs` · No test checks that `kix deploy` or `kix rollback` exits 1 when a resource fails.

`RunEnd::of` and `summary_line` have unit tests, but the `std::process::exit(1)` that follows `!end.succeeded` in `deploy::run` and `rollback::run_async` has none. The scripted-ops path through `run_deploy_async` is hard to reach from a test, and kind run K3 (`deploy-fail.log`) recorded `rc=0` before the fix. Nobody has checked the exit status on a cluster since.
