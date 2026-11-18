+++
kind = "changed"
packages = ["experimental/cdi"]
+++
`cdi` now warns when the cluster's `k8sVersion` is outside the Kubernetes versions CDI v1.66.1 is tested on, 1.35 and 1.36. The build still passes, because CDI states no supported versions and no version is known to fail. A cluster that sets no `k8sVersion` is not checked.
