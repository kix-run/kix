# 2026-10-02 · `kix/packages/valkey` · Wiring a Prometheus anywhere in the cluster restarts every valkey StatefulSet.

valkey adds its exporter sidecar when `config.metrics.enabled && prometheus != null`
(`kix/packages/valkey/default.nix`, `scrape`). The optional `prometheus`
dependency binds across namespaces, so adding a prometheus-operator in any
namespace changes the pod template and rolls every valkey StatefulSet; a
single-replica instance goes down for the roll. No rule flags an optional
dependency that changes a pod template. metabase now gates its metrics port
on `metrics.enabled` alone and gates only the Service port and the
ServiceMonitor on the dependency.
