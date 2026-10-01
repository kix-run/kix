# 2026-10-01 · `kix/lib/core/resource.nix` · `mkResource` and `mkImportResource` still default `clusterDomain` to `cluster.local`.

`mkScope` and `mkImportScope` now require the domain and pass it on, but the two core constructors keep `clusterDomain ? "cluster.local"`. A resource built through them directly, without a scope, gets an `out.fqdn` under `cluster.local` whatever the cluster's domain. The direct callers today are namespace objects, the Kix CRDs, the activation objects and a few tests, none of which publishes an fqdn anyone reads, so nothing renders wrong yet.
