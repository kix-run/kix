+++
kind = "changed"
packages = ["experimental/cilium"]
+++
`cilium` now warns when `k8sVersion` is outside Kubernetes 1.33 to 1.36, the versions Cilium 1.20 tests end to end. The build still succeeds: Cilium relies on Kubernetes' own compatibility for newer releases, and no version is known to fail. Clusters that leave `k8sVersion` unset are not checked.
