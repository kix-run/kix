+++
kind = "error"
id = "K3359"
packages = ["experimental/clickhouse-logs", "experimental/loki-logs"]
+++
`clickhouse-logs` and `loki-logs` now refuse a cluster whose `k8sVersion` is older than 1.32, because Vector 0.62.0 supports Kubernetes 1.32 and later. They accepted any Kubernetes version before. If your cluster sets an older `k8sVersion`, upgrade Kubernetes first, or stay on a Kix release with older `clickhouse-logs` and `loki-logs` packages. A cluster that sets no `k8sVersion` is not checked.
