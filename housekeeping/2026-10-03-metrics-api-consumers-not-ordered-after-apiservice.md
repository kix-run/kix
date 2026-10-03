# 2026-10-03 · `kix/lib/scope/validators.nix` · HPAs and the descheduler's KubernetesMetrics source are not ordered after the metrics.k8s.io APIService.

`scope.requireMetricsApi` and `checkHorizontalPodAutoscaler` check only that
the metricsApi role is served. They add no dependency on the metrics-server
instance, so on a fresh deploy an HPA or the descheduler can start before the
APIService is Available. HPAs report FailedGetResourceMetric until it is.
Whether the descheduler retries or exits at startup is unverified.
