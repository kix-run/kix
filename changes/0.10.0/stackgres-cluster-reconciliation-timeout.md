+++
kind = "silent"
packages = ["stackgres-cluster"]
+++
`stackgres-cluster` now writes `reconciliationTimeout: 3600` on each `backups`
entry, so StackGres has an hour instead of its five-minute default to delete
the base backups and WAL that retention no longer keeps. With the default, a
busy database's delete was cut off every night while the backup still
succeeded, and old backups piled up in the bucket. The SGCluster of every
cluster with `backups` changes on the next deploy. To keep StackGres's default,
set `reconciliationTimeout = null` on the entry.
