# 2026-11-02 · `kix/packages/tailscale` · The proxy policies admit traffic from the whole cluster to egress proxies as well as to LoadBalancer proxies.

`proxyPolicies` selects the proxy pods by the operator's parent-type labels (`svc`, `proxygroup`), which do not tell a LoadBalancer proxy from an egress proxy. Both get `fromCluster` ingress, so any pod can reach an egress proxy and through it the tailnet, while only the pods that dial the egress Service need to. Look at `serviceProxies` and `proxyGroups` in `kix/packages/tailscale/default.nix`.
