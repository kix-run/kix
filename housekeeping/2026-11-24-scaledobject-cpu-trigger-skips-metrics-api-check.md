# 2026-11-24 · `kix/lib/scope/validators.nix` · A KEDA ScaledObject with a cpu or memory trigger gets no metrics.k8s.io check.

`checkHorizontalPodAutoscaler` (validators.nix:330-350) warns when a raw
HorizontalPodAutoscaler reads resource metrics and nothing serves the
metricsApi role. A ScaledObject with a `cpu` or `memory` trigger makes KEDA
create the same kind of HPA at runtime, and Kix says nothing. Without
metrics-server the HPA reports FailedGetResourceMetric and never scales.
The keda package header states the limit.
