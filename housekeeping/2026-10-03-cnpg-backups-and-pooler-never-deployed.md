# 2026-10-03 · `kix/packages/cnpg-barman-cloud`, `cnpg-pooler` · Backups and the pooler have only been evaluated, never deployed.

`clusters/test-cnpg.nix` evaluates with WAL archiving, a ScheduledBackup, and a Pooler, but no kind run has shown that the operator registers the plugin from its Service and certificates, that the sidecar reaches the in-cluster store under default deny, or that Metabase logs in through PgBouncer. Deploy the cluster on kind and check the Cluster's ContinuousArchiving condition, a completed Backup, and Metabase's database connection.
