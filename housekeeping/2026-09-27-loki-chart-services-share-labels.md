# 2026-09-27 · `kix/packages/loki` · The loki chart's Services share their labels, so `architecture.distinctSameKindLabels` fails at error severity.

`Service/loki`, `Service/loki-memberlist`, `Service/loki-headless` and
`Service/loki-gateway` carry the same labels or subsets of each other's, so
a selector that finds one also finds the others. The labels come from the
chart, so the fix is in chart values. `ludo/base.nix` downgrades the rule
for `monitoring-loki`, and the `every-package-evaluates` check in
`kix/package-eval.nix` downgrades it for loki and for promtail, which
auto-instantiates loki.
