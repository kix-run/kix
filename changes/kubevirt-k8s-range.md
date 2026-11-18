+++
kind = "changed"
packages = ["experimental/kubevirt"]
+++
`kubevirt` now warns when the cluster's `k8sVersion` is outside the Kubernetes versions KubeVirt v1.9 supports, 1.34 to 1.36. The build still passes, because no version is known to fail. A cluster that sets no `k8sVersion` is not checked.
