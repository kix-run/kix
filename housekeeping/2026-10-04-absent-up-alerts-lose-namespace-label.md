# Nine package alerts fire with no namespace label

These alerts produce a result without a `namespace` label:

- The down alerts in cert-manager, coredns, reloader, and velero use
  `absent(up{<selector>} == 1)`. `absent()` copies labels into its result
  only when its argument is a plain selector. Wrapping the selector in
  `== 1` makes it an expression, so the alert carries only `alertname` and
  `severity`.
- velero's `VeleroBackupFailed` and `VeleroBackupMissing` aggregate
  `sum by (schedule)`.
- coredns's latency alert aggregates `by (server, zone, le)`, and its
  SERVFAIL alert divides two bare `sum(...)` results.
- harbor's core 5xx alert divides two bare `sum(...)` results.

Consequences:

- `{{ $labels.namespace }}` and `{{ $labels.service }}` in the description
  render empty.
- Alertmanager cannot group, route, or inhibit these alerts by namespace.
  The default route groups by `namespace`, so all of them land in one group
  with every other alert that lacks the label.

`promtool test rules` shows it for the `absent` form: the expected labels
`namespace` and `service` are missing from the fired alert.

Fix: for the down alerts,
`sum by (namespace, service) (up{<selector>}) == 0 or absent(up{<selector>})`;
for the others, add `namespace` and `service` to the `by` lists. HANDBOOK
§9.4 "Writing alerts" gives the patterns. This belongs to step 3 of issue
#192 (audit the packages that already alert).
