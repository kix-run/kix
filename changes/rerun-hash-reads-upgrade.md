+++
kind = "note"
state = true
+++
The first deploy after you upgrade runs some Jobs with `kix.run/rerun: on-change` one more time: each Job that reads a Secret or ConfigMap that Kix builds, because its `kix.run/rerun-hash` now includes that object's content, and each Job whose `checksum/*` annotations Kix's packages removed. These include the `stackgres-database` and `clickhouse-database` bootstrap Jobs, the webhook checks of `cnpg-operator`, `rabbitmq-operator`, and `external-secrets`, the `openbao` reconcile Job, and every `kix.healthCheck` probe. Each Job that Kix's packages write is safe to run again.
