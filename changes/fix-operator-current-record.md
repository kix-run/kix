+++
kind = "silent"
state = true
+++
When a Kix operator deploy ends `Failed`, the operator now returns the cluster to the build of the current Activation record: it deletes the resources the failed deploy added and re-applies the ones it changed. Before, the operator marked the current record `Superseded` before it applied anything, so a failed deploy left its changes in place and left the cluster with no current record. `kix status` showed nothing deployed, and `kix rollback --operator` needed the old record named by hand. Now the current record stays `Active` or `Degraded` until a new deploy finishes, as with `kix deploy`, and its drift repair waits while the new record is `Queued` or `Deploying`. A finished operator deploy now writes `status.previousActivation` and the `kix.run/previous` annotation, so `kix history` shows its predecessor. To inspect a failed deploy's resources, look at them while the operator is still retrying.
