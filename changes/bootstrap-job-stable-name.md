+++
kind = "note"
packages = ["experimental/stackgres-database", "experimental/clickhouse-database"]
+++
The `stackgres-database` and `clickhouse-database` bootstrap Jobs now keep one name, `<instance>-<namespace>-bootstrap`, and carry `kix.run/rerun: on-change`, so a new password no longer stops `kix deploy` with a stateful replacement. The deploy runs the Job again when the password's SOPS file, the package options, or the database server change. The first deploy after you upgrade renames each Job once. The Jobs with the old names stay on the cluster until a deploy with `--prune` deletes them.
