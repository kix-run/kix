# 2026-11-26 · `cli/kix/src/cluster/` · Two deploys of one Kix cluster can run at once.

Nothing stops a second `kix deploy` of a cluster while the first still
runs. The binding lock in `cluster/binding.rs` only ties a Kix cluster to
one Kubernetes cluster. A `Deploying` record of another deploy makes the
plan skip the fold of `Failed` and `Partial` records and print a note, and
then the deploy goes ahead. `kix deploy --only` makes this more likely,
because two people may each deploy one instance of the same build. Both
runs then write the same record, and the last one to finish sets its phase
and `status.partial`.
