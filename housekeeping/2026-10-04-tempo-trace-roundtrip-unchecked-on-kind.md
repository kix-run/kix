# 2026-10-04 · `kix/packages/tempo` · Nobody has sent a span through Tempo on Kubernetes or seen retention delete a block.

`clusters/test-tempo.nix` (S3 backend, Loki, Grafana, default deny) and `clusters/test-tempo-generator.nix` (metrics generator writing to VictoriaMetrics) deployed on kind on 2026-10-04, so the pod starts as uid 10001 on its claim and Grafana's datasources provision. Unchecked: a span pushed to `out.otlpHttpUrl` coming back from the querier, the generator's series reaching vminsert, and retention deleting a block. Deploy with `--keep` and push one span.
