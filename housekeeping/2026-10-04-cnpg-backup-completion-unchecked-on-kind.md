# 2026-10-04 · `kix/packages/cnpg-barman-cloud`, `cnpg-pooler` · The kind deploy did not check that a base backup completes or that Metabase connects through PgBouncer.

`clusters/test-cnpg.nix` deployed on kind on 2026-10-04 with WAL archiving, a ScheduledBackup, and a Pooler, and every declared readiness rule passed. Readiness does not cover the Cluster's ContinuousArchiving condition, a completed Backup in the in-cluster store, or Metabase's database connection through the Pooler. Deploy the cluster on kind with `--keep` and check those three.
