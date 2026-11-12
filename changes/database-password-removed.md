+++
kind = "error"
packages = ["experimental/stackgres-database", "experimental/cnpg-database", "experimental/clickhouse-database"]
id = "K9503"
+++
`stackgres-database`, `cnpg-database`, and `clickhouse-database` no longer take
`password`, which put the password in plain text in Kix's local store and in
the built Secrets. Give the password as the secret dependency `password`
instead, for example a `packages.secret` instance with a SOPS `source`
(see the record for `[K6023]`). A build that sets `password` fails with an
error that says how to make the change.
