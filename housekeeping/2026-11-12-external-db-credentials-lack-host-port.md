# 2026-11-12 · `kix/packages/experimental/*-database` · With a password from outside Kix, the database credentials Secret holds only `username` and `password`.

From a SOPS file the package renders a credentials Secret that also holds `database`, `host`, and `port`. From any other source the dependency itself is the credentials Secret, so an app that mounts the whole Secret, or reads `host` from it, finds those keys missing. Every consumer in the tree reads them from `out`, so nothing breaks today.
