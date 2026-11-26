# 2026-09-20 · `kix/lib/rules/architecture.nix` · The core rule set encodes prometheus-operator and VictoriaMetrics operator behaviour by kind name.

`monitorSelectorMatchesService` and `monitorsExternalService` match the kinds ServiceMonitor and VMServiceScrape by string and reimplement the operators' namespaceSelector and endpoint-port matching. `kix/lib/helm-dag.nix` does the same for ServiceMonitor and HTTPRoute when it infers chart edges. A new scrape kind today needs an edit to core.

Decision required from Adam: `discussions/147_operator_semantics_in_core_rules.md` frames it as a contract declaration on the CRD builder versus documenting the status quo. Nothing to fix until that is picked.
