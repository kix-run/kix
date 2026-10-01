# 2026-10-01 · `meta.network.intents` · Network intents are static, so a package's egress cannot follow its config or instance.

`meta` is read before an instance's config exists, so an intent cannot depend
on an option. `kix/packages/external-dns` therefore allows TCP 443 to the
world for every provider, including `inmemory`, which calls nothing, and
cannot open port 53 for `rfc2136`, 8081 for `pdns`, 80 for `pihole`, or 2379
for `coredns` and `skydns`. It warns for those providers under an enforcer and
the user adds a namespace NetworkPolicy by hand.
