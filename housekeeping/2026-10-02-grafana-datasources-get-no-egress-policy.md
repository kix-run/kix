# 2026-10-02 · `kix/packages/grafana` · Grafana gets no egress policy to the datasources it auto-wires, so under default-deny it cannot query Prometheus, Alertmanager or Loki.

The datasource URLs (`prometheusServer.out.serviceUrl`, `loki.out.serviceUrl`)
land in `ConfigMap/grafana-datasources`, which the k8s-sidecar reads through
the API instead of a volume mount. No pod spec references the ConfigMap, so
the derived policy never sees the addresses. On `ludo#cluster-ludo-kind`
(`networkPolicy.enable = true`) the rendered
`grafana-deployment-grafana-egress` CiliumNetworkPolicy allows DNS only,
and no caller-ingress policy admits Grafana at `loki` or `prometheus-operated`.
Fix by carrying the datasource ConfigMap's context into the Deployment (or
mounting it when the sidecar is off), then check every datasource answers
in Grafana on a kind cluster with Cilium.
