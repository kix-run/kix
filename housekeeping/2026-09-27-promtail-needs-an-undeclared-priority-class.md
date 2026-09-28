# 2026-09-27 · `kix/packages/promtail` · promtail sets `priorityClassName = "monitoring-loki"` but neither creates that PriorityClass nor depends on it.

On its own, promtail fails the cross-resource check: "DaemonSet
promtail/promtail sets priorityClassName 'monitoring-loki', which no
resource in this cluster creates". Only `kix/lib/modules/monitoring.nix`
supplies the class, so a cluster that installs promtail without that
module does not build. The `every-package-evaluates` check in
`kix/package-eval.nix` adds a priority-classes instance for it.
