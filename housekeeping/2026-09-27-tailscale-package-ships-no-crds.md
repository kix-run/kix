# 2026-09-27 · `kix/packages/tailscale` · The tailscale package emits ProxyClass and Connector objects but ships none of the tailscale.com CRDs.

The upstream chart installs the CRDs (`installCRDs: true`), and the
operator's reconcilers watch Connector, ProxyClass, ProxyGroup, DNSConfig
and Recorder. A cluster that sets `proxyClasses` or `connectors` fails
to apply them unless something outside Kix installed the CRDs first.
The package's `meta.version` is "1.0.0" while its images are v1.82.0.
