# 2026-10-02 · `kix/lib/core/resource.nix` · `mkResource` drops `spec = { }`, so a resource whose CRD requires `spec` cannot be built with an empty one.

resource.nix:268 adds `spec` only when it is not `{ }`. SGPoolingConfig, SGInstanceProfile, and SGScript list `spec` as required, so an empty spec is rejected by the API server at apply time, not at evaluation. stackgres-cluster works around it by writing an empty `pgBouncer."pgbouncer.ini"` for `pooling = { }`.
