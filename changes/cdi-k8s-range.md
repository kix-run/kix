+++
kind = "changed"
packages = ["experimental/cdi"]
+++
`cdi` now warns when `k8sVersion` is outside Kubernetes 1.35 to 1.36, the versions CDI v1.66.1 tests in end-to-end CI (CDI publishes no Kubernetes support policy). The build still succeeds because no version is known to fail. Clusters that leave `k8sVersion` unset are not checked.
