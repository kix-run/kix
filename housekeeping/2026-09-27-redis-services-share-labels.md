# 2026-09-27 · `kix/packages/redis` · The redis chart's Services share their labels, so `architecture.distinctSameKindLabels` fails at error severity.

`Service/redis-headless` carries a subset of the labels on
`Service/redis-master` and `Service/redis-replicas`, so a selector that
finds the headless Service also finds the other two. The labels come from
the chart, so the fix is in chart values. The `every-package-evaluates`
check in `kix/package-eval.nix` downgrades the rule for redis, as
`ludo/base.nix` does for loki.
