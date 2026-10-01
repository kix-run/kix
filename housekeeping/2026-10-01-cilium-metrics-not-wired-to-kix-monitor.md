# 2026-10-01 · `kix/packages/cilium` · Cilium's agent and operator metrics are off and not wired to `kix.monitor`.

The package leaves the chart's `prometheus.enabled` off and turns `operator.prometheus.enabled` off, because both open host ports (the pods are host-networked) and no Kix scrape target or alert reads them. The cluster gets no Cilium agent, operator or Hubble metrics. Wiring them needs a `metrics` option and an optional `prometheus` dep that emit ServiceMonitors through `kix.monitor`, and a way to scrape host-network ports under default-deny.
