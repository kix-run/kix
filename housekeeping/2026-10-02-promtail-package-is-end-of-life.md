# 2026-10-02 · `kix/packages/promtail` · We ship Promtail, and Grafana ended its life on 2 March 2026.

Grafana's Loki docs say Promtail gets no further updates and that Grafana Alloy
replaces it. Clusters that ship logs to `loki` through this package run an
unmaintained agent. kixpkgs has no Alloy, Fluent Bit, or OpenTelemetry
Collector package to move to.
