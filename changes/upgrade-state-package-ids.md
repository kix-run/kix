+++
kind = "silent"
cli = ["kix upgrade"]
+++
If a script or tool reads `packagesInUse` from `kix-upgrade.json`, update it to read `packageIdsInUse` instead. `kix-upgrade.json` now records built-in package IDs (such as `harbor` or `experimental/coredns`) in `packageIdsInUse`, replacing the instance names in `packagesInUse`. If you resume an upgrade started with an older version of Kix, `kix upgrade` does not mark release notes with `*` during that run.
