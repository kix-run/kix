# 2026-10-01 · `kix/packages/victoria-metrics-operator` · The operator's self-monitor VMServiceScrape never becomes ready on a cluster with no VMAgent.

`crds.nix` declares readiness `/status/updateStatus = "operational"` for every
VM kind. On a fresh kind cluster, `kix deploy victoria-metrics-crd-ref`
(operator, vm-cluster and a consumer, no victoria-metrics-agent) created every
resource, VMCluster went ready, and then
`VMServiceScrape/victoria-metrics-operator-monitor` stayed at
`currently <absent>` until the 300s ceiling stopped the deploy. The status
appears to be written only when a VMAgent selects the scrape, so the
self-monitor (`metrics` on by default) blocks any deploy of the operator
without an agent. Seen during the W0.7 kind run of the rework.
