+++
kind = "fixed"
+++
The Kix operator now leaves alone an `Active` or `Degraded` Activation record that `kix deploy` wrote without `--operator`. Previously, the operator added its finalizer to that record and logged `reconcile failed: ReconcilerFailed(MissingSourcePath, ...)` every 30 seconds, because the record names no build for the operator to repair.
