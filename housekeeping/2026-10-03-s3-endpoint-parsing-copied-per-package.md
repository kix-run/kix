# 2026-10-03 · `kix/packages/{cnpg-cluster,velero,tempo}` · Each package that takes an S3 store parses the endpoint and checks for a Service host with its own copy of the code.

cnpg-cluster has `matchUrl`, `urlHostInCluster`, and `urlPort`; velero has its own `urlPort`; tempo has `matchEndpoint` and an inline `.svc` check for Tempo's `host[:port]` form. The three copies already differ in what they accept, and a fourth consumer would add another. A shared helper for "endpoint to world egress port, refusing in-cluster hosts" would live in `kix/lib/vocab`.
- Hit again 2026-10-03: tempo now also refuses single-label hosts (`minio:9000`), which cnpg-cluster and velero accept. None of them can tell `<service>.<namespace>` from a public domain.
