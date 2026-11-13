# 2026-11-13 · `kix/packages/experimental/stackgres-database`, `clickhouse-database` · A changed password from a secret-ref does not run the bootstrap Job again.

The bootstrap Job's name carries a hash of its inputs, and the password's part
of that hash is `out.sops.digest`. A password from `packages.secret-ref` has no
digest, so the input is `null` and stays the same when the site changes the
Secret. The Job does not run again, and the database keeps the old password
while the app reads the new one.
