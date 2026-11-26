# 2026-11-26 · `cli/kix/src/cluster/head/` · A record that a run before the deploy lock left `Deploying` is never cleared.

The lock marks a dead run's record `Failed` when the next run takes the
lock over. A record left `Deploying` by a run that held no lock, because an
older Kix made it before the upgrade, has no lock to take over, so it stays
`Deploying`. Every later plan then prints the in-flight note and skips the
fold of `Failed` and `Partial` records, until someone patches the record.
