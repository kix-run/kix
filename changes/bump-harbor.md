+++
kind = "silent"
packages = ["harbor"]
touches-data = true
+++
`harbor` now runs Harbor 2.15.5 instead of 2.15.2, a patch release with security fixes. The first deploy after you upgrade restarts every Harbor pod, and core migrates the database: three columns become `bigint`. Harbor 2.15.2 does not start on a database that 2.15.5 has migrated, so going back with `kix rollback` leaves core failing to start. To go back, restore a database backup taken before the upgrade, then deploy the older version. Back up the database before you upgrade if you might need to go back. Webhooks to internal addresses keep working as they did in 2.15.2. Signing clients such as `cosign` and `notation` can still pull an unsigned image in a project that requires signed images, but only with push permission on the project, and no longer when the project blocks vulnerable images.
