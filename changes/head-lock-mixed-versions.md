+++
kind = "note"
state = true
+++
An older Kix does not know the deploy lock: its `kix deploy`, `kix rollback`, and `kix gc` neither take the lock nor wait for it, and its `kix gc` does not see that a newer Kix wrote to the cluster. After this release deploys a cluster, do not run an older Kix's `kix gc` on it, and upgrade everyone who deploys the cluster, including CI and the Kix operator, together. When an older Kix deploys anyway, the next run of this release rebuilds the head from the deploy records.
