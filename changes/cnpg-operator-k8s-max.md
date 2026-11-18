+++
kind = "changed"
packages = ["cnpg-operator"]
+++
`cnpg-operator` now warns when the cluster's `k8sVersion` is outside the Kubernetes versions CloudNativePG 1.30 states support for, 1.34 to 1.36. The build still passes, because no version from 1.31 is known to fail. It still refuses a `k8sVersion` older than 1.31.
