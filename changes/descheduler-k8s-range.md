+++
kind = "changed"
packages = ["experimental/descheduler"]
+++
`descheduler` now warns when `k8sVersion` is outside Kubernetes 1.35 to 1.37, the versions descheduler 0.37 is tested against. The build still succeeds: descheduler has no hard dependency on a specific Kubernetes release, and no version is known to fail. Clusters that leave `k8sVersion` unset are not checked.
