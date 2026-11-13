# 2026-11-13 · `kix plan` · A Job that will run again is listed as "tracking annotation only; no spec change or restart".

When only a Secret that a `kix.run/rerun` Job references changes, `kix plan example --offline` prints `~ Job/immich-db-immich-bootstrap@immich (tracking annotation only; no spec change or restart)`, and a few lines later says the same Job "will be deleted and recreated so they run again". The first line is wrong for a rerun Job, and a reader who stops at it misses that the Job runs.
