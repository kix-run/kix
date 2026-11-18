+++
kind = "changed"
packages = ["experimental/infisical-operator"]
+++
`infisical-operator` now warns when the cluster's `k8sVersion` is outside the Kubernetes versions Infisical states support for, 1.29 to 1.33. The build still passes, because no version is known to fail. A cluster that sets no `k8sVersion` is not checked.
