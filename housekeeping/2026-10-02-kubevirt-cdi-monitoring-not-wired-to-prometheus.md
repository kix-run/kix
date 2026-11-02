# 2026-10-02 · `kix/packages/{kubevirt,cdi}` · KubeVirt and CDI monitoring is not wired to a Prometheus dependency.

virt-operator and cdi-operator create their own ServiceMonitor and
PrometheusRule whenever the prometheus-operator CRDs exist, outside the Kix
graph. Neither package takes an optional `prometheus` dependency. The
prometheus package selects every ServiceMonitor and PrometheusRule in every
namespace, so it loads both operators' upstream rules and targets. Under a
network-policy enforcer, though, nothing derives the scrape edge to the
KubeVirt and CDI pods, because the netpol plugin reads only monitors in the
graph, so their alerts see no series. Neither operator can be told not to
create its objects: virt-operator checks only API discovery
(`pkg/virt-operator/util/client.go` `IsServiceMonitorEnabled`, v1.5.0), and
cdi-operator only whether the PrometheusRule kind resolves
(`pkg/operator/controller/prometheus.go` `isPrometheusDeployed`, v1.62.0).
`monitorAccount` and `MONITORING_NAMESPACE` only name the subject of a
RoleBinding, which the prometheus package's ClusterRole makes unneeded.

Decision required from Adam: keep the operators' own monitors and add a
`prometheus ? null` dependency that only opens the scrape edge, or scrape
through `kix.monitor` with package alerts and accept that the operators'
duplicate monitors and rules stay.
- Hit again 2026-11-02 while adding operator alerts.
