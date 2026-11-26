+++
kind = "added"
+++
A `dns` import can list where pods send DNS queries in `out.dnsPeers`, as pods by label in one namespace (`{ namespace; podSelector; }`) or an address range (`{ cidr; }`). Kix builds the DNS egress rule of every generated network policy from that list. Without it, the rule allows the `kube-dns` pods in `kube-system`, as before. The `gke` and `gke-autopilot` flavors list `kube-dns`, `node-local-dns`, `169.254.169.254/32`, and `169.254.20.10/32`. The `cilium` package's `cilium-cluster-dns-egress` policy allows the same peers. Built manifests stay the same on every cluster that runs Cilium.
