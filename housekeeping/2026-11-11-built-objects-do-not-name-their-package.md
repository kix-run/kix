# 2026-11-11 · `cli/kix-cli/src/commands/upgrade/` · A built object names its instance, never its package, so `kix upgrade` matches change records by instance name.

Change records name packages under `kix/packages/`, but a build carries only the instance name (`kix.run/package`, PackageInstance `spec.instanceName`), and `kix list packages --cluster` lists instances too. An instance renamed with an alias does not match its package's records: those records do not apply, and its changed objects count as having no change record. Look at `packages_in_use` and `compare::load_dir`.
