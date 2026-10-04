# 2026-10-04 · `prometheus-default-rules` · KubePersistentVolumeFillingUp never fires for claims on local-path-provisioner.

The rule reads `kubelet_volume_stats_*`, and the kubelet reports none for
hostPath-backed volumes, which is what kind's default StorageClass gives.
So on kind, and on any cluster using local-path, no generic alert notices a
full claim. Loki and Tempo now carry their own disk alerts, but every other
stateful package (postgres, valkey, clickhouse, and others) relies on the
generic rule and is blind there. Sources: alerts-research note on Loki and
Tempo, https://github.com/ugur99/local-path-provisioner-pv-metrics-exporter.
