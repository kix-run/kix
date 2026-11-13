# 2026-10-18 · `kix deploy` · Rotating a stackgres-database password is refused as a stateful migration.

The bootstrap Job's name carries a hash of the password, so a new `passwordHash` renames the Job, and the deploy reports "Job/immich-db-bootstrap-<old> -> Job/immich-db-bootstrap-<new>" under "Stateful migrations detected" and stops. A Job holds no data, so the only way through is `--accept-migrations`, which also waves through any real migration in the same deploy.
- Still true 2026-11-13 with the SOPS digest: changing the password in `clusters/dev-secrets/immich-db.sops.yaml` makes `kix plan example` exit 3 with the bootstrap Job listed under "Stateful workload replacements".
