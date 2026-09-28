# 2026-09-27 · `kix/packages/smartctl-exporter` · The chart's ServiceMonitor selects `app.kubernetes.io/managed-by=Helm`, a label no Service carries after import, so it scrapes nothing.

`architecture.monitorSelectorMatchesService` reports it at error
severity: the selector includes `managed-by=Helm`, `app.kubernetes.io/version`
and `helm.sh/chart`, and the imported Service carries none of those
values. The `every-package-evaluates` check in `kix/package-eval.nix`
downgrades the rule for this package. No cluster installs it.
