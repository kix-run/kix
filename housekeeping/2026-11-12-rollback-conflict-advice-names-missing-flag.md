# 2026-11-12 · `kix rollback` · A rollback that hits a field ownership conflict says to run again with `--force-conflicts`, which `kix rollback` does not take.

`kix rollback --dry-run` did not report the conflict either, though `kix plan` reports the same one ("The deploy would stop on 1 write"). The rollback then applied the ConfigMap, failed on the Deployment, and left the cluster between two builds. Reproduce with `kubectl scale` on a Kix Deployment, then `kix rollback`.
