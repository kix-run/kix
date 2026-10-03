# 2026-10-03 · `cli/kix-cli/src/commands/deploy.rs` · A reviewed plan does not record `--on-error`, so it cannot say whether the refusals it shows stop the deploy.

A plan with refusals stops a deploy under `--on-error stop` and applies the
rest under `--on-error continue`. The saved plan records only the planning
flags, so `kix deploy --plan plan.json --on-error continue` makes a partial
apply that the reviewer may have expected to stop.
