+++
kind = "error"
id = "K9973"
packages = ["kube-state-metrics"]
+++
`kube-state-metrics` now refuses a cluster whose `k8sVersion` is not 1.36, the one Kubernetes version kube-state-metrics 2.20.0 supports. It accepted 1.25 and every later version before. On Kubernetes 1.35 and older, kube-state-metrics 2.20.0 reads MutatingAdmissionPolicy through an API version those releases do not serve. If your cluster sets another `k8sVersion`, move it to Kubernetes 1.36 first, or stay on a Kix release with an older `kube-state-metrics` package. A cluster that sets no `k8sVersion` is not checked.
