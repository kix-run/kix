# 2026-10-02 · `cli/kix/src/cluster/scheduler.rs` · Prune deletes a custom resource and its operator in one pass, so a finalizer the operator removes is never removed.

Prune deletes orphans in reverse dependency order with background
propagation and does not wait for them to go (`scheduler.rs` prune pass,
`ops/resources.rs` prune). Removing a `mayastor` instance deletes its DiskPools
and operator-diskpool together; the DiskPools keep the operator's finalizer
and stay Terminating with no operator left to clear it. The install-mayastor
how-to tells users to remove the pools first and wait. Any operator whose
custom resources carry a finalizer has the same problem.
- Hit again 2026-10-02 by `kix/packages/arc`: removing a runner set together with arc or with its `githubConfigSecret` leaves the AutoscalingRunnerSet Terminating, because its finalizer needs the controller and the secret to deregister the scale set. The arc and arc-runner-set headers tell users to remove the runner set first.
- Hit again 2026-11-24 by `kix/packages/experimental/db-operator-instance`: a Database's finalizer needs the DbInstance it names, which has no finalizer of its own, so pruning a db-operator-database together with its db-operator-instance (or with db-operator) leaves the Database Terminating. The db-operator-instance header tells users to remove the databases first and wait.
- Hit again 2026-11-24 by `kix/packages/experimental/db-operator-instance`: narrowing a DbInstance's `extraSpec.namespaceFilters` and removing the db-operator-database instances in the excluded namespaces in one deploy left those Databases in Terminating with "namespace a-b is not allowed on the instance", because the controller checks the filter before it handles a deletion. `kix deploy --prune` reported them as pruned, and `kix status` then reported every resource `ok` because the Databases had left the build. The db-operator-instance header and how-to tell users to remove the databases before narrowing the filters.
