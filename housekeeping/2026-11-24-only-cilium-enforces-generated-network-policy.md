# 2026-11-24 · `kix/lib/plugins/netpol` · Generated network policy has one enforcer, Cilium, and no Kubernetes `NetworkPolicy` output.

Only `packages.experimental.cilium` claims `network-policy-enforcer`, so `networkPolicy.enable = true` on a cluster running Calico, Antrea, or a cloud CNI with plain `NetworkPolicy` support fails evaluation. Every generated object is a `CiliumNetworkPolicy` or `CiliumClusterwideNetworkPolicy`. The enforcer contract (`interface.nix`) would allow a second enforcer that renders `networking.k8s.io/v1` objects, but none exists.
