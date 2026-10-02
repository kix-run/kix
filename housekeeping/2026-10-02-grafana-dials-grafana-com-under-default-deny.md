# 2026-10-02 · `kix/packages/grafana` · Grafana still opens connections to grafana.com at start although the package turns update checks off.

Under ludo-kind's default deny, Cilium dropped two connections per Grafana pod start to 34.120.177.193:443 (W6 kind run K2), the address grafana.com resolves to. `grafana.ini` already sets `reporting_enabled`, `check_for_updates`, and `check_for_plugin_updates` to false, so some other feature dials out; which one is not known yet. Nothing visibly breaks, but each start logs a failed outbound call and waits on it.
