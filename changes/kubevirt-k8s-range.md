+++
kind = "changed"
packages = ["experimental/kubevirt"]
+++
`kubevirt` now warns when `k8sVersion` is outside Kubernetes 1.34 to 1.36, the versions KubeVirt v1.9 lists as supported. The build still succeeds because no version is known to fail. Clusters that leave `k8sVersion` unset are not checked.
