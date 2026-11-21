+++
kind = "error"
id = "K8826"
packages = ["experimental/spegel"]
+++
If your cluster uses `spegel` and sets `k8sVersion` below 1.34, upgrade the cluster to Kubernetes 1.34 or newer and update `k8sVersion` before upgrading Kix, or stay on an older version of Kix. `spegel` now fails the build below 1.34 because its registry Service sets `trafficDistribution: PreferSameNode`, which Kubernetes 1.33 and older reject. When `k8sVersion` is 1.34 or newer than 1.37, outside the 1.35 to 1.37 range that Spegel 0.8.1 supports, the build succeeds with a warning. Clusters that leave `k8sVersion` unset are not checked.
