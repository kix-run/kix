+++
kind = "error"
packages = ["experimental/stackgres-database", "experimental/cnpg-database", "experimental/clickhouse-database"]
id = "K9503"
+++
`stackgres-database`, `cnpg-database`, and `clickhouse-database` no longer take
`password`, which put the password in plain text in Kix's local store and in
the built Secrets. Set `passwordSource` to a SOPS-encrypted file with a
`password` key, and `passwordHash` to the content hash of the decrypted
password. A build that sets `password` fails with an error that names these
two options.
