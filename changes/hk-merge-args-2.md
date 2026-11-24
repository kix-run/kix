+++
kind = "note"
packages = ["node-exporter"]
+++
`node-exporter` now passes `--collector.textfile.directory` before the flags in `extraArgs` instead of after them. This changes the argument list of the DaemonSet only for an instance that sets a non-empty `extraArgs` and keeps `textfileCollector.enabled` on, which is the default. On the first deploy after you upgrade, Kubernetes restarts the exporter pod on each node of such an instance once. Other instances do not change. You do not need to change anything.
