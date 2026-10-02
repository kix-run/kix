# 2026-10-02 · `kix/lib/eval/auto.nix` · An auto-instantiated cluster-scoped operator lands in the namespace of the first package that needs it.

A cluster with `immich` and a `stackgres-database` but no `stackgres-operator`
instance gets the operator's Deployment, ServiceAccount, Service and CRD
markers in immich's namespace (trace: `auto-instantiated: ...,
stackgres-operator (photos)`). The operator then shares its lifecycle with one
app. The `immich` package header asks users to declare `stackgres-operator`
once in its own namespace; nothing enforces that.
