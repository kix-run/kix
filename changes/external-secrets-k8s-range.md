+++
kind = "changed"
packages = ["experimental/external-secrets"]
+++
`external-secrets` now warns when the cluster's `k8sVersion` is outside the Kubernetes versions External Secrets Operator v2.15 states support for, which is 1.37 only. The build still passes, because no version is known to fail. A cluster that sets no `k8sVersion` is not checked.
