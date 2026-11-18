+++
kind = "changed"
packages = ["experimental/cilium"]
+++
`cilium` now warns when the cluster's `k8sVersion` is outside the Kubernetes versions Cilium 1.20 lists as tested, 1.33 to 1.36. The build still passes, because Cilium states that newer versions depend on Kubernetes' compatibility and no version is known to fail. A cluster that sets no `k8sVersion` is not checked.
