+++
kind = "note"
packages = ["experimental/stackgres-database", "experimental/clickhouse-database"]
+++
The `stackgres-database` and `clickhouse-database` bootstrap Jobs now keep one name, `<instance>-<namespace>-bootstrap`. Before, the name held a hash of the password, so a new password renamed the Job and stopped `kix deploy` with a stateful replacement. The Jobs now carry `kix.run/rerun: on-change`, and the deploy runs them again when the password's SOPS file, the package options, or the database server change. On the first deploy after you upgrade, each bootstrap Job gets its new name and runs once with the same password, which it does safely. The deploy does not stop for this. The Job with the old name stays on the cluster until a deploy with `--prune` deletes it.
