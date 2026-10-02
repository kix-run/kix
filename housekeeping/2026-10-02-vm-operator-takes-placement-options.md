# 2026-10-02 · `kix/packages/victoria-metrics-operator` · victoria-metrics-operator takes placement options that duplicate `partsOverlays`.

It takes `nodeSelector`, `tolerations`, and `affinity`, each a copy of one pod-spec field under the same name, so a cluster author meets two ways to place the same pod, and other packages offer only the instance's `partsOverlays` (BEST-PRACTICES §5.3). It also takes a `logLevel` option that only sets the `--zap-log-level` flag, which `extraArgs` could carry.
