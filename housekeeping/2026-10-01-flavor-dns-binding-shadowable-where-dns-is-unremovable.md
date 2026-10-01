# 2026-10-01 · `kix/lib/flavors/{gke,gke-autopilot,aks}.nix` · The `dns` role is `shadowable` on platforms whose DNS cannot be replaced.

Every flavour binds `cluster.roles.dns` as `shadowable`. On GKE, GKE Autopilot and AKS the kubelet always points pods at the platform's DNS, so a coredns instance there becomes the `dns` provider for a server no pod queries: workloads order after it and nothing resolves through it. Binding `dns` as `exclusive` on those flavours would refuse a managed DNS provider at evaluation.
