+++
kind = "changed"
packages = ["experimental/openbao"]
+++
`openbao` now warns when the cluster's `k8sVersion` is outside the Kubernetes versions OpenBao 2.7.2 states support for, 1.35 to 1.37. The build still passes, because no version is known to fail. A cluster that sets no `k8sVersion` is not checked.
