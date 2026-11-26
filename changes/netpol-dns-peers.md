+++
kind = "added"
packages = ["experimental/coredns"]
library = ["kix.mkImport"]
+++
The package that provides the `dns` role can list where pods send DNS queries in `meta.dnsPeers`, and `kix.mkImport` takes the same list as its new `dnsPeers` argument. Each entry selects pods by label (`{ namespace; podSelector; }`, where a missing `namespace` means the provider's own namespace) or an IP range (`{ cidr; }`, which the `cilium` enforcer refuses). Kix builds the DNS egress rule of every generated workload policy and of `cilium-cluster-dns-egress` from that list, and still allows the `k8s-app: kube-dns` pods in `kube-system` when the list is unset, so existing clusters build the same manifests. The `coredns` package lists its own pods, so under `networkPolicy.enable` it no longer has to run in `kube-system`. The `gke` and `gke-autopilot` flavors list `kube-dns`, `node-local-dns`, `169.254.169.254/32`, and `169.254.20.10/32`.
