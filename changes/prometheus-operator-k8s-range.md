+++
kind = "error"
id = "K2247"
packages = ["experimental/prometheus-operator"]
+++
`prometheus-operator` now refuses a cluster whose `k8sVersion` is newer than
1.37, the newest Kubernetes version the prometheus-operator v0.95.2 tests
run on. It accepted 1.25 and every later version before. If your cluster
sets a newer `k8sVersion`, stay on a Kix release with an older
`prometheus-operator` package until a newer one supports your Kubernetes
version. A cluster that sets no `k8sVersion` is not checked.
