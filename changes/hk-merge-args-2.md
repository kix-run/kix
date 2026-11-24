+++
kind = "note"
packages = ["node-exporter"]
+++
No configuration changes are needed. If a `node-exporter` instance sets a non-empty `extraArgs` and leaves `textfileCollector.enabled` on (the default), the first deploy after you upgrade restarts its pod on each node once. `node-exporter` now passes `--collector.textfile.directory` before `extraArgs` instead of after it, which reorders the DaemonSet's container arguments on those instances. Other `node-exporter` instances do not change.
