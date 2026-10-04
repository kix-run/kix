# 2026-10-04 · `kix/packages/velero` · VeleroBackupMissing cannot fire when `metrics.maxBackupAge` is longer than the Prometheus retention.

The rule reads `velero_backup_attempt_total offset <maxBackupAge>`. The
prometheus package keeps 7d of data (`retention = "7d"` in
`kix/packages/prometheus/default.nix`), so with an age over 7d the `offset`
selector finds no sample and the rule returns nothing. The option's own
example, `"8d"`, is such a value, and a weekly schedule needs one. A site
that follows the example has a backup alert that never fires. See
`VeleroBackupMissing` in `kix/packages/velero/default.nix`.
