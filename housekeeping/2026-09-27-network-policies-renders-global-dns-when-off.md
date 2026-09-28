# 2026-09-27 · `kix/packages/network-policies` · `global-dns` renders even when `clusterwidePolicies.globalDns` is false.

The package uses `self.global-dns` as its `root`, and `root` must be a
named part, so the policy is always in the output. A cluster that turns
`globalDns` off still gets a `CiliumClusterwideNetworkPolicy/global-dns`
allowing DNS to `kube-system`.
