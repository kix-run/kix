+++
kind = "error"
id = "K8720"
packages = ["experimental/cilium"]
+++
`cilium` now refuses a cluster whose `k8sVersion` is outside the Kubernetes versions Cilium 1.20 supports, 1.33 to 1.36. It accepted 1.27 and every later version before. If your cluster sets an older or newer `k8sVersion`, upgrade Kubernetes first, or stay on a Kix release with an older `cilium` package. A cluster that sets no `k8sVersion` is not checked.
