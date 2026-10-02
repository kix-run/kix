# 2026-10-02 · `kix/packages/{kubevirt,cdi}` · KubeVirt and CDI monitoring is not wired to a Prometheus dependency.

virt-operator and cdi-operator create their own ServiceMonitor and
PrometheusRule when the prometheus-operator CRDs exist, in their own
namespace by default, outside the Kix graph. Neither package takes an
optional `prometheus` dependency, so a Prometheus in another namespace finds
those objects only if a user sets KubeVirt's `monitorNamespace` and
`monitorAccount` through `extraSpec`. `prometheus.out` does not expose its
namespace and ServiceAccount (`kix/packages/prometheus/default.nix:958-966`)
for the packages to read.
