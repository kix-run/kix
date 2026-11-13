+++
kind = "error"
packages = ["experimental/stackgres-database", "experimental/cnpg-database", "experimental/clickhouse-database"]
id = "K6023"
+++
`stackgres-database`, `cnpg-database`, and `clickhouse-database` no longer
take `passwordSource` and `passwordHash`. They take the password as a secret
dependency named `password`, so it can come from any source: a SOPS file, a
Secret that a secrets operator writes, or an External Secrets object. To
keep your SOPS file, add a `packages.secret` instance beside the database
with `source` set to the old `passwordSource` and `keys = [ "password" ]`.
Leave out the old `passwordHash`, because Kix computes the digest of the
file itself (see `[K4732]`).
Give it `aliases = [ "password" ]`, or set `deps.password` on the database
when a namespace has more than one. The database's Secrets keep their
names and values, and the deploy also creates the new instance's own Secret. A
build that sets `passwordSource` or `passwordHash` fails with an error that
says how to make the change.
