+++
kind = "changed"
packages = ["experimental/openbao"]
+++
`openbao` now warns when `k8sVersion` is outside Kubernetes 1.35 to 1.37, the versions OpenBao 2.7.3 lists as supported. The build still succeeds because no version is known to fail. Clusters that leave `k8sVersion` unset are not checked.
