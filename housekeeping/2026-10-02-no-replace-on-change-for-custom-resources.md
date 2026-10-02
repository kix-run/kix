# 2026-10-02 · `cli/kix/src/cluster/scheduler.rs` · A package cannot ask for a custom resource to be deleted and re-created when it changes.

Deploy recreates an object only on an immutable-field conflict for an orphan.
Some operators delete their own objects on a change instead: the arc
controller deletes an AutoscalingRunnerSet whose `app.kubernetes.io/version`
label has another major.minor than its build, so a release change in
`kix/packages/arc` needs a second `kix deploy --reconcile` to bring the runner
sets back. A per-kind or per-resource "replace when this field changes" switch
would let the package do it in one deploy.
