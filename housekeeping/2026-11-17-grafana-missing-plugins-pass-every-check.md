# 2026-11-17 · `kix/packages/stable/grafana` · No check notices when Grafana starts without the plugin a data source needs.

Grafana 13.3 moved the Prometheus, Loki, and Tempo data sources out of its
binary and into `/usr/share/grafana/data/plugins-bundled`. The package
mounted an empty folder over that path, so the pod became ready while every
wired data source failed with "Plugin unavailable". Evaluation, `kix check`,
the readiness probe, and `kix deploy` all passed. Only a request through a
data source found it. The same upgrade also dropped the Parca data source.
A deploy-time check that calls each wired data source's
`/api/datasources/uid/<uid>/health` would catch both.
