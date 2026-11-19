+++
kind = "changed"
packages = ["cnpg-operator"]
+++
`cnpg-operator` now warns when `k8sVersion` is outside Kubernetes 1.34 to 1.36, the versions CloudNativePG 1.30 lists as supported. When `k8sVersion` is 1.31 to 1.33 or newer than 1.36, the build still succeeds because no version from 1.31 onward is known to fail. `cnpg-operator` continues to refuse `k8sVersion` values below 1.31, and leaves clusters without `k8sVersion` unchecked.
