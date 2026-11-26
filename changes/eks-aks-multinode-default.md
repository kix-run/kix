+++
kind = "changed"
+++
`kix.flavors.eks` and `kix.flavors.aks` now set `cluster.capabilities.multiNode = true` by default, matching `gke`, `gke-autopilot`, `ovh`, and `scaleway`. Multi-node clusters need no changes, and generated manifests do not change because Kix already spread pods across nodes when `multiNode` was unset; if your EKS or AKS cluster runs on a single node, set `cluster.capabilities.multiNode = false`. Builds no longer warn that `cluster.capabilities.multiNode` is unset or that required pod anti-affinity might not schedule, and instead warn until you set `cluster.capabilities.availabilityZones` to your zone names (or `[ ]` for a single zone).
