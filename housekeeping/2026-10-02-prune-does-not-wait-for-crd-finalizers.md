# 2026-10-02 · `cli/kix/src/cluster/scheduler.rs` · Prune deletes a custom resource and its operator in one pass, so a finalizer the operator removes is never removed.

Prune deletes orphans in reverse dependency order with background
propagation and does not wait for them to go (`scheduler.rs` prune pass,
`ops/kube.rs` delete). Removing a `mayastor` instance deletes its DiskPools
and operator-diskpool together; the DiskPools keep the operator's finalizer
and stay Terminating with no operator left to clear it. The install-mayastor
how-to tells users to remove the pools first and wait. Any operator whose
custom resources carry a finalizer has the same problem.
