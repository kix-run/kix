+++
kind = "note"
+++
You do not need to change your configuration before upgrading. On the first deploy after you upgrade, some Jobs with `kix.run/rerun: on-change` run one more time, and all affected Jobs in Kix's packages are safe to run again. A Job runs once more if its pod reads a Secret or ConfigMap built by Kix, because `kix.run/rerun-hash` now includes that object's content, or if Kix's packages removed a `checksum/*` annotation from its pod template. Affected built-in Jobs include the `stackgres-database` and `clickhouse-database` bootstrap Jobs, the `cnpg-operator`, `rabbitmq-operator`, and `external-secrets` webhook checks, the `openbao` reconcile Job, and every `kix.healthCheck` probe.
