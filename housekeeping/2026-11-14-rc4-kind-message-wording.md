# 2026-11-14 · CLI messages · Small wording problems found testing 0.10.0-rc.4 on kind.

- "left the build, still running on the cluster" is used for a completed Job
  and a PodDisruptionBudget, which do not run. "Still on the cluster" fits.
- The plan shows a version change `cert-manager v1.21.2 -> 1.21.2`, which is
  only the dropped "v". It could be left out when the versions are equal
  after normalising.
- Checksum annotations show as `(secret, not shown)` and
  `(secret, changed, not shown)`. They are hashes, not secrets.
- "↻ 3 Job(s) ... will be deleted and recreated" counts a Job that is new,
  so nothing is deleted for it.
- `[K6054]` in a project with `library = "self"` says to run
  `kix upgrade --to <the running version>`, which does nothing there.
