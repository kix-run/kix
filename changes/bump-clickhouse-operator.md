+++
kind = "error"
packages = ["experimental/clickhouse-operator", "experimental/clickhouse-cluster"]
id = "K7577"
+++
`clickhouse-operator` now deploys Altinity clickhouse-operator 0.27.4, up from 0.27.3. The operator no longer reads user settings that start with `k8s_secret_` or `k8s_secret_env_`. It stops reconciling a ClickHouseInstallation that still has them, so the build now refuses them with `[K7577]`. This affects a `clickhouse-cluster` `extraSpec`, or a ClickHouseInstallation built with `mkClickHouseInstallation`, that sets such a field in `spec.configuration.users`. Replace each field with the same field without the prefix, set to `valueFrom.secretKeyRef` with the name and key of a Secret in the installation's namespace. The upgrade restarts the operator pod only. ClickHouse and Keeper pods keep running, and the new operator takes over the installations the old one created.
