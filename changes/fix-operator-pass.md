+++
kind = "fixed"
+++
The Kix operator now skips `Active` and `Degraded` `Activation` records that have no `spec.source.path`, such as records created by `kix deploy` without `--operator`. Previously, the operator added its `kix.run/operator-gc` finalizer to those records and logged `reconcile failed: ReconcilerFailed(MissingSourcePath, ...)` every 30 seconds when trying to check them for drift.
