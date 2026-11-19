+++
kind = "changed"
packages = ["experimental/external-secrets"]
+++
`external-secrets` now warns when `k8sVersion` is not Kubernetes 1.37, the only minor version External Secrets Operator v2.15 lists as supported. The build still succeeds because no version is known to fail. Clusters that leave `k8sVersion` unset are not checked.
