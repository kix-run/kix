# 2026-11-14 · CLI messages · Small wording problems found testing 0.10.0-rc.4 on kind.

- The plan shows a version change `cert-manager v1.21.2 -> 1.21.2`, which is
  only the dropped "v". It could be left out when the versions are equal
  after normalising.
- Checksum annotations show as `(secret, not shown)` and
  `(secret, changed, not shown)`. They are hashes, not secrets.
- "↻ 3 Job(s) ... will be deleted and recreated" counts a Job that is new,
  so nothing is deleted for it.
- `kix plan` still says "still running on the cluster" for objects that left
  the build (`cli/kix-cli/src/plan/mod.rs` and `plan/render.rs`). The deploy,
  gc, and log messages now say "still on the cluster".
