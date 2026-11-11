# 2026-11-11 · `cli/kix/src/cluster/stream.rs` · `DeployResult::cancelled` counts objects never sent and objects cut off mid-apply together.

Dependents of a failed node are never sent to the cluster. On Ctrl-C or a
stall abort, in-flight nodes are aborted after their apply may have landed,
and they get the same `Cancelled { External }` verdict and the same count. The
closing line of a deploy therefore cannot say whether the held-back objects
changed the cluster.
