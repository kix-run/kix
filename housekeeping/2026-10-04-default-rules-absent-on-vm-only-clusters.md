# 2026-10-04 · `kix/packages/prometheus-default-rules` · A cluster that runs VictoriaMetrics without prometheus-operator gets none of the generic Kubernetes rules.

`prometheus-default-rules` requires a `prometheusOperator` dependency that is
the prometheus-operator package (it reads `out.kubeletService`), and
`kix/lib/modules/monitoring.nix` wires it only for the Prometheus stack. So
`clusters/test-victoria-metrics.nix` and any VM-only site run without
TargetDown, KubePodCrashLooping, KubePersistentVolumeFillingUp, and Watchdog.
Package-review item Mo19 tells authors to leave those conditions to the
generic rules, which on such a cluster means nobody alerts on them.
victoria-metrics-alert now ships its own Watchdog; the rest is still missing.

Decision required from the maintainers: have prometheus-default-rules render through
any rule and monitor builder (the VictoriaMetrics operator's `mkVMRule` and
VMServiceScrape as well as prometheus-operator's), or keep it
Prometheus-only and say in Mo19 that a VM-only cluster carries no generic
rules. See `v2_discussions/101_monitoring_provider_landscape.md`.
