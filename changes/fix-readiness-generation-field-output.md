+++
kind = "changed"
cli = ["kix deploy"]
+++
`kix deploy` now prints `ready, restart pending: <reason>` for a resource whose running workload keeps the previous spec until a restart. For an `OnDelete` DaemonSet the reason gives how many pods still run the previous pod template. The line used to read `ready, <n> pods pending manual restart (OnDelete)`. The JSON log's `pending_restart` event keeps its fields, and `stale` is 1 for a custom resource.
