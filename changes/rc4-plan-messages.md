+++
kind = "silent"
cli = ["kix plan", "kix plan --read-only", "kix rollback"]
+++
The plan document's `schema_version` is now `2026-11-14`, so a script that reads `kix plan -o json` must accept the new version. A plan of a build with no changes no longer counts its unchanged Jobs under `kix.run/rerun` as objects to write. In `objects.writes` such a Job is now `if_last_run_failed`, because the deploy runs it again only if its last run failed. `kix plan --read-only` now exits 0, as `kix plan` does, when the only difference is an object an earlier deploy left on the cluster. It lists that object under `prune` and no longer as removed by the build. `kix rollback` now prints the Jobs it will run again, as `kix deploy` does. A Job that is new to the cluster is no longer listed as deleted and recreated. A `checksum/*` annotation, and a Secret's content and applied hashes, now read `(hash, not shown)` in place of `(secret, not shown)`.
