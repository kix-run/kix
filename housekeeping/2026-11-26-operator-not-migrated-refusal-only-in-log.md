# 2026-11-26 · `cli/kix-operator/src/controller.rs` · The operator says only in its log that it will not repair drift on a Kix cluster an older Kix deployed last.

`LivePlanError::NotMigrated` becomes `OperatorError::ReconcileError`, and `error_policy` logs it as a warning and requeues every 30 seconds. No Event or status field on the Activation record tells the user to run `kix deploy` once, so drift repair can stay off unnoticed after an upgrade.
