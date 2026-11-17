+++
kind = "silent"
packages = ["valkey"]
touches-data = true
+++
`valkey` now runs Valkey 9.1.3 instead of 8.1.10. Valkey 9 reads the data files of 8.1, so the first deploy after you upgrade restarts the pods once and keeps the data. A standalone instance is down while its pod restarts. Valkey 9 then writes its data files in a format that Valkey 8.1 refuses to load, so going back to 8.1, for example with `kix rollback`, leaves the pods failing to start. To go back, also set `settings.rdb-version-check = "relaxed"` on the instance. Valkey 8.1 then loads the files, unless a hash has fields with their own expiry time (set with `HSETEX` or `HEXPIRE`). Back up the data volume before you upgrade if you might need to go back.
