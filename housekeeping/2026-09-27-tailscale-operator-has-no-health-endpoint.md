# 2026-09-27 · `kix/packages/tailscale` · The Tailscale operator has no health endpoint, so the package has no liveness or readiness probe.

`cmd/k8s-operator/operator.go` at v1.82.0 sets no `HealthProbeBindAddress`
on its controller-runtime manager, and the tailscale-operator chart
(1.82.0) renders no probes. On kind, with dummy OAuth credentials, the
Deployment was reported Ready by `kix deploy` before the operator exited
on "creating operator authkey: ... 401 Unauthorized". `reliability.hasProbes`
warns twice for tailscale.
