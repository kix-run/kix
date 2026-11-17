+++
kind = "error"
id = "K3530"
packages = ["experimental/cert-manager"]
+++
`cert-manager` now refuses a cluster whose `k8sVersion` is outside the Kubernetes versions cert-manager v1.21 supports, 1.33 to 1.36. It accepted 1.37 and later before. If your cluster sets one of those versions, upgrade Kubernetes first, or stay on a Kix release with an older `cert-manager` package. A cluster that sets no `k8sVersion` is not checked.
