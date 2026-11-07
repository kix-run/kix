# 2026-11-07 · `kix plan` · `kix plan` lists the changed objects in a different order on each run of the same build.

Two runs of `kix plan stage2` on the same Lithus monorepo tree printed the same lines and the same plan hash, but the `~ SGPostgresConfig/...` and `~ SGInstanceProfile/...` entries in the `backup-rehearsal` namespace swapped places. A person or a script comparing two plans sees changes that are not there. `kix diff` on the same tree printed the same order each time.
