+++
kind = "error"
id = "K1442"
packages = ["victoria-metrics-operator"]
+++
`victoria-metrics-operator` now refuses a cluster whose `k8sVersion` is newer than 1.37, the newest Kubernetes version operator v0.75.2 is tested on. It accepted 1.25 and every later version before. If your cluster sets a newer `k8sVersion`, stay on a Kix release with an older `victoria-metrics-operator` package until a newer one supports it. A cluster that sets no `k8sVersion` is not checked.
