+++
kind = "added"
+++
When a delete does not finish (`[K2794]`) before an in-place recreate, or while `kix deploy`, `kix rollback`, or the Kix operator waits for an object of the build that is already being deleted, the error now names the controller that the object's kind names (`controller` on `scope.mkCRD`) and says whether it is ready, not ready, or not on the cluster, as a stuck prune delete already did. In `--log-format json`, every delete that does not finish now fails with the detail `deletion_unfinished` (`elapsed_ms`, `finalizers`, `controllers`, and `message`), and a prune delete that waits for its object to be gone is reported in `waiting` events with `phase` `deletion`, which the line log prints as `waiting>` lines.
