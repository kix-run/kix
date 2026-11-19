+++
kind = "changed"
packages = ["experimental/kubevirt"]
+++
`kubevirt` now warns when `k8sVersion` is outside Kubernetes 1.35 to 1.37, the versions KubeVirt v1.10 supports under its release policy. The build still succeeds because no version is known to fail. Clusters that leave `k8sVersion` unset are not checked.
