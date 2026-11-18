+++
kind = "error"
id = "K9973"
packages = ["kube-state-metrics"]
+++
`kube-state-metrics` now refuses a cluster whose `k8sVersion` is older than 1.36. It accepted 1.25 and every later version before. kube-state-metrics 2.20.0 reads MutatingAdmissionPolicy objects through an API version that Kubernetes 1.35 and older do not serve. If your cluster sets an older `k8sVersion`, move it to Kubernetes 1.36 first, or stay on a Kix release with an older `kube-state-metrics` package. On a `k8sVersion` newer than 1.36 the build passes with a warning, because upstream states support for 1.36 only. A cluster that sets no `k8sVersion` is not checked.
