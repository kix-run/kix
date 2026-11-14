+++
kind = "silent"
cli = ["kix plan", "kix plan --read-only", "kix rollback"]
+++
Update scripts that read `kix plan -o json` to accept `schema_version`
`2026-11-14`.

A plan of a build with no changes no longer counts unchanged Jobs that carry
`kix.run/rerun` as objects to write. In `objects.writes`, such a Job now has
change `if_last_run_failed`, because the deploy runs it again only if its last
run failed. A Job that is new to the cluster is no longer listed as deleted
and recreated.

`kix plan --read-only` now exits 0, as `kix plan` does, when the only
difference is an object an earlier deploy left on the cluster. It lists that
object under `prune` instead of as removed by the build. `kix rollback` now
prints the Jobs it will run again, as `kix deploy` does.

`checksum/*` annotations, a Secret's content hash, and a Secret's applied hash
now read `(hash, not shown)` instead of `(secret, not shown)`.
