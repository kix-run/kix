# 2026-10-01 · `kix/packages/grafana` · grafana builds its own Ingress from a chart-style `ingress` option instead of calling `kix.expose`.

The `ingress` option (`kix/packages/grafana/default.nix`, the `ingress` option and the `ingress` part) mirrors the upstream chart's `hosts`, `tls` and `ingressClassName`, and `rootUrl` is set by hand. So grafana gets no HTTPRoute on a Gateway API cluster, no cert-manager TLS from a wired `clusterIssuer`, no ingress-controller network policy, and no `exposure` record to derive `root_url` from.
