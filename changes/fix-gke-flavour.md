+++
kind = "fixed"
+++
If you run a single-node `gke` cluster, set `cluster.capabilities.multiNode = false`. The `gke` flavor now defaults `multiNode` to `true` (matching GKE's default of three nodes per zone), so `gke` builds no longer warn that `multiNode` is unset. Cluster definitions can also set `instances.<namespace>.platform-dns.optional` on any flavor without `lib.mkForce`. Previously, overriding it on any flavor except `kind` failed with "conflicting definition values".
