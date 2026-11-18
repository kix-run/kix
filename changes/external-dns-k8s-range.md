+++
kind = "error"
id = "K3140"
packages = ["experimental/external-dns"]
+++
`external-dns` now refuses a cluster whose `k8sVersion` is older than 1.21, the oldest Kubernetes version external-dns 0.24.0 supports. It accepted every version before. Move the cluster to Kubernetes 1.21 or later first. A cluster that sets no `k8sVersion` is not checked.
