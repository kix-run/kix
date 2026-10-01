# 2026-10-01 · `kix/lib/flavors/*.nix` · The flavours' `platform-dns` imports spell out the DNS Service address by hand, and `out.name` names a different object.

Each flavour's `kix.mkImport` sets `out.fqdn = "kube-dns.kube-system.svc.${config.clusterDomain}"` (openshift: `dns-default.openshift-dns`) and `out.name = "coredns"`, which names the Deployment while the fqdn names the Service. Twelve copies can drift, and a consumer reading `out.name` for the Service gets the wrong object. A `scope.mkServiceRef`-style import would derive both from one Service name and namespace.
