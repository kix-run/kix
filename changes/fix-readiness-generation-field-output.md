+++
kind = "changed"
cli = ["kix deploy"]
+++
`kix deploy` now prints `ready, restart pending: <reason>` for a resource whose running workload keeps the previous spec until a restart. For an `OnDelete` DaemonSet the reason gives how many pods still run the previous pod template. The line used to read `ready, <n> pods pending manual restart (OnDelete)`. The JSON log's `pending_restart` detail keeps its fields and still covers only `OnDelete` DaemonSets. A custom resource in that state gets the new `awaiting_restart` detail, which carries the message.
