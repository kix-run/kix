# 2026-10-02 · `kix/packages/node-exporter` · node-exporter's own alerts share names with alerts in prometheus-default-rules, so a cluster with both gets two notifications for one disk.

node-exporter ships `NodeFilesystemSpaceFillingUp` and `NodeFilesystemAlmostOutOfSpace`, and the `node-exporter` rule group of prometheus-default-rules ships alerts of the same names with other thresholds. With `monitoring.defaultRules.enabled` (ludo, ludo-kind) both fire for one filesystem. Nothing tells a package that the cluster also carries a rule set covering its metrics.
