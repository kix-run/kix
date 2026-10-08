# 2026-10-03 · `cli/kix/src/plan/server.rs` · `kix plan --force-conflicts` does not show a takeover of fields whose values already match.

`comparable` strips `managedFields`, so a forced apply that takes a field from
another manager without changing its value shows no change. The other
manager, for example an HPA or a controller, then loses that field to Kix
without the plan saying so.
