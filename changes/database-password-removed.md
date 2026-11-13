+++
kind = "error"
packages = ["experimental/stackgres-database", "experimental/cnpg-database", "experimental/clickhouse-database"]
id = "K9503"
+++
`stackgres-database`, `cnpg-database`, and `clickhouse-database` no longer take
`password`, which put the password in plain text in Kix's local store and in
the built Secrets. Give the password as the secret dependency `password`
instead, for example a `packages.secret` instance with a SOPS `source`
(see `[K6023]`). A password secret that Kix does not fill from a SOPS file
must also hold `username`, equal to the database's `user`, and list both
keys in `keys`. A build that sets `password` fails with an error that says
how to make the change.
