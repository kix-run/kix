+++
kind = "changed"
+++
The `eks` and `aks` flavors now set `cluster.capabilities.multiNode = true` by default, as the `gke`, `gke-autopilot`, `ovh`, and `scaleway` flavors do. Generated manifests do not change: Kix already spread pods across nodes when `multiNode` was unset. The build no longer warns that `cluster.capabilities.multiNode` is not set, or that a workload's required anti-affinity may not schedule. It warns instead that `cluster.capabilities.availabilityZones` is not set, as it does on `gke`, until the cluster lists its zones. A cluster that runs on a single node sets `cluster.capabilities.multiNode = false`.
