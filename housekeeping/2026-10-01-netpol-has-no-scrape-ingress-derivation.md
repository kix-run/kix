# 2026-10-01 · `kix/lib/plugins/netpol` · A ServiceMonitor creates no scraper-to-target edge, so every Kix scrape is dropped under default deny.

`kix.monitor` and `prometheus.out.mkServiceMonitor` build a ServiceMonitor that selects the package's metrics Service, but derived policy reads Service references from pod specs, and the scraper's pods never name the target. With `networkPolicy.enable` the target namespace's default deny drops the scrape and the target shows `up == 0`. No package opens its metrics port with `meta.network.intents`, because an intent cannot name the scraper and would admit every source. Affected: `kix/packages/cert-manager` (ports 9402 on three Deployments). The fix is a lib derivation from the ServiceMonitor to an ingress rule from the prometheus instance's pods.

Under an enforcer, cert-manager's `CertManagerAbsent` alert (`absent(up{...} == 1)` on the controller Service) therefore fires on every cluster until this is fixed.

- Hit again 2026-10-02 by `kix/packages/mayastor`: the io-engine metrics exporter runs on the host network, so the scraper reaches it as the host or a remote node, which no derived rule admits.
- Hit again 2026-10-02 by `kix/packages/ingress-nginx`: its ServiceMonitor scrapes Service `<name>-metrics` on 10254, which a default-deny cluster such as ludo-kind drops.
