+++
kind = "added"
+++
No changes are required for existing clusters; to allow DNS queries to custom endpoints under generated network policy, set `out.dnsPeers` on your `dns` `kix.mkImport` instance. Each entry selects pods in a namespace (`{ namespace; podSelector; }`) or an IP range (`{ cidr; }`; rejected by the `cilium` enforcer, which supports pod selectors only). Kix uses `out.dnsPeers` for the DNS egress rule in every generated workload policy and in `cilium-cluster-dns-egress`, and still defaults to `k8s-app: kube-dns` pods in `kube-system` when `out.dnsPeers` is unset. The `gke` and `gke-autopilot` flavors now set `out.dnsPeers` to `kube-dns`, `node-local-dns`, `169.254.169.254/32`, and `169.254.20.10/32`.
