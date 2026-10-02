# 2026-10-01 · `meta.network.intents` · Network intents are static, so a package's egress cannot follow its config or instance.

`meta` is read before an instance's config exists, so an intent cannot depend
on an option. `kix/packages/external-dns` therefore allows TCP 443 to the
world for every provider, including `inmemory`, which calls nothing, and
cannot open port 53 for `rfc2136`, 8081 for `pdns`, 80 for `pihole`, or 2379
for `coredns` and `skydns`. Under an enforcer it warns for those providers,
and the user adds a namespace NetworkPolicy for the port.
- Hit again 2026-10-02 while reworking `kix/packages/cert-manager`. The webhook's `from = "apiserver"` ingress cannot carry `webhook.securePort`, so it admits the API server on every port. The controller's egress to issuers is fixed at 443, 80, and 53, so an Issuer that names Vault on 8200 or a private ACME directory on another port is dropped under an enforcer.
