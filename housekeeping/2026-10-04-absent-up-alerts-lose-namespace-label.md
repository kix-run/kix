# Four "down" alerts fire with no namespace or service label

The down alerts in cert-manager, coredns, reloader, and velero use
`absent(up{<selector>} == 1)`. `absent()` copies labels into its result only
when its argument is a plain selector. Wrapping the selector in `== 1` makes
it an expression, so the alert carries only `alertname` and `severity`.

Consequences:

- `{{ $labels.namespace }}` and `{{ $labels.service }}` in the description
  render empty.
- Alertmanager cannot group, route, or inhibit these alerts by namespace.
  The default route groups by `namespace`, so all four land in one group
  with every other unlabelled alert.

`promtool test rules` shows it: the expected labels `namespace` and
`service` are missing from the fired alert.

Fix: `sum by (namespace, service) (up{<selector>}) == 0 or absent(up{<selector>})`.
Both branches carry `namespace` and `service`. HANDBOOK §9.4 "Writing
alerts" gives the pattern. This belongs to step 3 of issue #192 (audit the
packages that already alert).

Files: `kix/packages/cert-manager/default.nix`,
`kix/packages/coredns/default.nix`, `kix/packages/reloader/default.nix`,
`kix/packages/velero/default.nix`.
