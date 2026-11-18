+++
kind = "error"
id = "K4518"
packages = ["experimental/descheduler"]
+++
`descheduler` now refuses a cluster whose `k8sVersion` is outside the Kubernetes versions descheduler 0.37 supports, 1.35 to 1.37. It accepted every Kubernetes version before. If your cluster sets an older or newer `k8sVersion`, upgrade Kubernetes first, or stay on a Kix release with an older `descheduler` package. A cluster that sets no `k8sVersion` is not checked.
