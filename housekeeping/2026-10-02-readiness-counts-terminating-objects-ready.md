# 2026-10-02 · `cli/kix/src/cluster/readiness.rs` · Readiness treats an object with a `deletionTimestamp` as ready.

`wait_for_ready` and `check_readiness` never read `metadata.deletionTimestamp`.
An apply onto an object that is being deleted can succeed while its finalizers
run, and the object then disappears after the deploy reports success. Seen in
the design of `kix/packages/arc`: after a minor release change the new
controller deletes every AutoscalingRunnerSet with the old version label, and
an apply that lands during that deletion reads the old `Running` phase. The
package header tells users to run `kix deploy --reconcile` afterwards.
