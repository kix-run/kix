# 2026-10-02 · `cli/kix/src/cluster/scheduler.rs` · `DeployError::ActivationError` is never constructed.

Nothing in the workspace builds the variant, so every match on
`DeployError` carries an arm for a case that cannot happen, and
`DeployError::partial` returns `None` only for it. Readers have to check
whether a record write can end a run this way; none can.
