+++
kind = "changed"
packages = ["experimental/descheduler"]
+++
`descheduler` now warns when the cluster's `k8sVersion` is outside the Kubernetes versions descheduler 0.37 is tested against, 1.35 to 1.37. The build still passes, because descheduler has no hard dependency on a Kubernetes release and no version is known to fail. A cluster that sets no `k8sVersion` is not checked.
