# 2026-09-30 · `kix diff` with victoria-metrics-operator · The VMRules and VMServiceScrapes that vm-operator converts from PrometheusRules and ServiceMonitors show as removals.

On stage2 the diff listed `- VMRule/coredns-dns-alerts`, `- VMServiceScrape/grafana-monitor` and four more, whose PrometheusRule and ServiceMonitor sources are still in the build. A reader has to work out that nothing will be lost.
