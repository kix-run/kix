+++
kind = "fixed"
+++
A cluster definition can now set `instances.<namespace>.platform-dns.optional` on any flavor without `lib.mkForce`. Before, every flavor except `kind` set it with normal priority, so a different value failed with "conflicting definition values". The `gke` flavor now sets `cluster.capabilities.multiNode = true`, because a GKE node pool has three nodes in each zone by default, so GKE builds no longer warn that `multiNode` is not set. Set it to `false` for a single-node cluster.
