+++
kind = "added"
+++
When `kix deploy`, `kix rollback`, or the Kix operator times out waiting for an object to finish deleting (`[K2794]`) before recreating or replacing it, the error now names any controller set with `controller` on `scope.mkCRD` or `scope.mkCRDRef` and reports whether it is ready, not ready, or not on the cluster, matching stuck prune deletes. In `kix deploy --log-format json`, any resource that fails with `[K2794]` now carries `deletion_unfinished` under `detail` (`elapsed_ms`, `finalizers`, `controllers`, and `message`). While `kix deploy --prune` waits for a deleted object to be removed from the cluster, `--log-format json` emits periodic `waiting` events with `phase` set to `"deletion"`, and `--log-format line` prints `waiting>` lines.
