+++
kind = "error"
id = "K5312"
packages = ["harbor"]
+++
`harbor` now refuses a cluster whose `k8sVersion` is older than 1.20, because Harbor 2.15.5 supports Kubernetes 1.20 or later. It accepted every version before. If your cluster sets an older `k8sVersion`, upgrade Kubernetes first, or stay on a Kix release with an older `harbor` package. A cluster that sets no `k8sVersion` is not checked.
