# 2026-10-01 · `meta.network.intents` · Network intents are static, so a package's egress cannot follow its config or instance.

`meta` is read before an instance's config exists, so an intent cannot depend
on an option. `kix/packages/external-dns` therefore allows TCP 443 to the
world for every provider, including `inmemory`, which calls nothing, and
cannot open port 53 for `rfc2136`, 8081 for `pdns`, 80 for `pihole`, or 2379
for `coredns` and `skydns`. Under an enforcer it warns for those providers,
and the user adds a namespace NetworkPolicy for the port.
- Hit again 2026-10-02 by `kix/packages/mayastor`: io-engine, agent-ha-node, and the CSI node plugin need ingress from host-network peers and egress to node agents on fixed ports, written as one package-wide `hostNetworkPeers` intent.
