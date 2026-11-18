+++
kind = "error"
id = "K0297"
packages = ["experimental/kubevirt"]
+++
`kubevirt` now refuses a cluster whose `k8sVersion` is outside the Kubernetes versions KubeVirt v1.9 supports, 1.34 to 1.36. It accepted every version before. If your cluster sets an older or newer `k8sVersion`, move Kubernetes into that range first, or stay on a Kix release with an older `kubevirt` package. A cluster that sets no `k8sVersion` is not checked.
