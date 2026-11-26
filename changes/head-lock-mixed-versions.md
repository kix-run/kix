+++
kind = "note"
state = true
+++
Upgrade Kix everywhere that changes a cluster at the same time, including CI and the Kix operator, and do not run `kix gc` with an older version of Kix after this version has changed the cluster. Older versions of Kix do not use the deploy lock: their `kix deploy`, `kix rollback`, and `kix gc` neither take the lock nor wait for it, and an older `kix gc` cannot see that a newer version of Kix wrote to the cluster. If an older version of Kix deploys anyway, the next run of this version rebuilds `ActivationHead` from the deployment records.
