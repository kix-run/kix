+++
kind = "fixed"
+++
The in-cluster operator and `kix rollback` now refuse to skip a required stop, as `kix deploy` already did. Before, a cluster last deployed with an older Kix could move past a release that changes what Kix stores in the cluster, without being deployed once with that release. The operator marks the queued Activation `Failed` with the reason and emits a `RequiredStopSkipped` event. `kix rollback` stops with `Rollback blocked:` and exits 1.
