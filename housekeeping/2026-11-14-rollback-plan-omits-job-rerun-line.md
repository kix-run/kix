# 2026-11-14 · `kix rollback` · The rollback plan does not print the Job rerun line, but the rollback reruns the Job.

Found testing 0.10.0-rc.4 on kind. `kix rollback example --dry-run`, and the
plan section of the real rollback, leave out "↻ N Job(s) with kix.run/rerun
changed their own content and will be deleted and recreated", which a deploy
plan prints. The rollback then reruns the database bootstrap Job. This is
another case of rollback rendering its plan apart from deploy (see the
existing entry on rollback duplicating deploy).
