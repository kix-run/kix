+++
kind = "changed"
packages = ["stackgres-database", "cnpg-database", "clickhouse-database"]
+++
`stackgres-database`, `cnpg-database`, and `clickhouse-database` warn when `password` is set, because the password then sits in plain text in Kix's local store and in the built Secrets. The build still uses it. Kix 0.10 removes `password`. Set `passwordSource` to a SOPS-encrypted file with a `password` key, and `passwordHash` to the content hash of the decrypted password.
