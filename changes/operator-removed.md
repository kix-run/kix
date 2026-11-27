+++
kind = "added"
state = true
cli = ["kix deploy --operator-removed", "kix plan --operator-removed"]
+++
Pass `--operator-removed` to `kix deploy <cluster>` once after uninstalling the Kix operator to return a Kix cluster to CLI management. Kix refuses with `[K9557]` to modify a cluster whose active, queued, or deploying deployment record was submitted to an older operator, because Kix cannot distinguish an older operator from an uninstalled one. Running `kix deploy <cluster> --operator-removed` marks queued operator records `Superseded`, marks in-progress operator records `Failed`, and clears `spec.source` from those records and the active record before showing the plan (so those record updates persist even if you decline the plan). Later commands do not need `--operator-removed` unless `kix rollback` restores an older operator-managed record. Do not pass `--operator-removed` while an older operator is still running, and do not combine it with `--operator`. `kix plan --operator-removed` previews the plan and records `flags.operator_removed` without modifying cluster records.
