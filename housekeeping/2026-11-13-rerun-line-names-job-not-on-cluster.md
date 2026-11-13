# 2026-11-13 · `kix plan` · The rerun line says a Job "will be deleted and recreated" when no Job of that name exists yet.

On the first deploy after upgrading, `immich-db-immich-bootstrap` is a new name. The plan still says "↻ 1 Job(s) with kix.run/rerun will be deleted and recreated so they run again: Job/immich-db-immich-bootstrap@immich", and the same plan lists the Job as added under "Stateful workload replacements". Nothing is deleted. The line should count only Jobs that are on the cluster.
