# 2026-10-04 · `kix/lib/vocab/compose.nix` (`kix.options.monitor`) · There is no option set for a package whose scrape an operator owns, so the VM packages declare their own `metrics.enabled`.

victoria-metrics-cluster, -agent, and -alert need `metrics.enabled` to switch
their `kix.alerts` rules, but the operator creates the scrape, so
`kix.options.monitor`'s `interval` would do nothing and its `enabled`
description promises a scrape it cannot turn off. Each package declares a
bare `metrics.enabled` instead, which package-review item Mo1 flags. The
same gap applies to any operator-scraped package that adopts `kix.alerts`.
