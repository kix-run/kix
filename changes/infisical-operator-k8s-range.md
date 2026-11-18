+++
kind = "changed"
packages = ["experimental/infisical-operator"]
+++
`infisical-operator` now warns when `k8sVersion` is outside Kubernetes 1.29 to 1.33, the versions Infisical's operator documentation lists as supported. The build still succeeds because no version is known to fail. Clusters that leave `k8sVersion` unset are not checked.
