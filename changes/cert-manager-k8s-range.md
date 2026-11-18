+++
kind = "changed"
packages = ["experimental/cert-manager"]
+++
`cert-manager` now warns when `k8sVersion` is outside Kubernetes 1.33 to 1.36, the versions cert-manager v1.21 lists as supported. The build still succeeds because no version is known to fail. Clusters that leave `k8sVersion` unset are not checked.
