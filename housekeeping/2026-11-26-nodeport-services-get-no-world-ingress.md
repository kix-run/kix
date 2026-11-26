# 2026-11-26 · `kix/lib/plugins/netpol/derive.nix` · A NodePort Service's backend gets no ingress rule from outside the cluster.

`processInstance` writes the `world` ingress supplement only for workloads a `LoadBalancer` Service selects. Under default deny, traffic to a `NodePort` Service from outside the cluster reaches its pods with no rule that admits it, so a package must add a `from = "world"` intent by hand. Before the external ingress rule named the LoadBalancer's ports, such a backend was admitted by accident when the instance also had a LoadBalancer Service.
