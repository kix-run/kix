+++
kind = "changed"
packages = ["experimental/cert-manager"]
+++
`cert-manager` now warns when the cluster's `k8sVersion` is outside the Kubernetes versions cert-manager v1.21 states support for, 1.33 to 1.36. The build still passes, because no version is known to fail. A cluster that sets no `k8sVersion` is not checked.
