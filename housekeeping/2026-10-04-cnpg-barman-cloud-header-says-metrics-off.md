# 2026-10-04 · `kix/packages/cnpg-barman-cloud` · The header says the plugin's metrics stay off, but its backup metrics are scraped through the instances.

"the plugin's metrics endpoint stays off" is true of the plugin Deployment's
own endpoint only. The sidecar in each instance pod publishes
`barman_cloud_cloudnative_pg_io_*` through the instance manager's port 9187,
which cnpg-cluster scrapes and alerts on. A reader of cnpg-barman-cloud
alone would conclude that backups are not monitored.
