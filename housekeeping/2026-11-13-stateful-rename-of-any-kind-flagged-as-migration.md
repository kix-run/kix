# 2026-11-13 · `cli/kix/src/cluster/migrate.rs` · Renaming any object in a stateful package is reported as a stateful replacement, even when the object holds no data.

`detect_migration_pairs` pairs a removed object with an added one of the same kind in the same package, and every object of a `lifecycle = "stateful"` package carries the stateful mark. So a renamed Job, ConfigMap, or NetworkPolicy stops `kix deploy` until `--accept-migrations`, and that flag also lets through any real migration in the same deploy. The `kix.run/holds-data` mark exists but only decides pairs across kinds.

Decision required from Adam: which objects of a stateful package can be one side of a migration pair.
