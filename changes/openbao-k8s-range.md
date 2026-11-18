+++
kind = "error"
id = "K6360"
packages = ["experimental/openbao"]
+++
`openbao` now refuses a cluster whose `k8sVersion` is outside the Kubernetes versions OpenBao 2.7.2 supports, 1.35 to 1.37. It accepted every Kubernetes version before. If your cluster sets one of those versions, upgrade Kubernetes first, or stay on a Kix release with an older `openbao` package. A cluster that sets no `k8sVersion` is not checked.
