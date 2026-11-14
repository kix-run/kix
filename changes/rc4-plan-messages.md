+++
kind = "silent"
cli = ["kix plan", "kix plan --read-only", "kix rollback"]
+++
Update scripts that read `kix plan --read-only -o json` or a saved plan file
to accept `schema_version` `2026-11-14`.

`kix plan` no longer counts unchanged Jobs with `kix.run/rerun` as objects to
write unless their last run failed. In `objects.writes`, such a Job now has
`change` set to `if_last_run_failed`, because the deploy runs it again only if
its last run failed. A new Job with `kix.run/rerun` is no longer listed as
deleted and recreated.

`kix plan --read-only` now exits 0, like `kix plan`, when the only difference
is an object left on the cluster by an earlier deploy. It lists that object
under `prune` instead of as removed by the build. `kix rollback` now prints
the Jobs it will run again, like `kix deploy`.

In plans and diffs, `checksum/*` annotations and a Secret's content and
applied hashes now read `(hash, not shown)` instead of `(secret, not shown)`.
