# 2026-11-26 · `kix/lib/plugins/netpol/derive.nix` · Workloads behind a NodePort Service get no external ingress rule.

`processInstance` generates `external-ingress-supplement` policies only for workloads selected by a `LoadBalancer` Service. Under default deny, network policy blocks outside traffic to a `NodePort` Service's pods unless the package declares a `from = "world"` ingress rule in `meta.network.intents`.
