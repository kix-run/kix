# 2026-10-02 · `kix/lib/eval/auto.nix` · An auto-instantiated cluster-scoped operator lands in the namespace of the first package that needs it.

A cluster with `immich` and a `stackgres-database` but no `stackgres-operator`
instance gets the operator's Deployment, ServiceAccount, Service, and CRD
markers in immich's namespace (trace: `auto-instantiated: ...,
stackgres-operator (photos)`). The operator then shares its lifecycle with one
app. The `immich` package header asks users to declare `stackgres-operator`
once in its own namespace; nothing enforces that. A consumer in another
namespace binds to that copy (a package marked one per cluster is placed once,
`mkItem` in `eval/auto.nix`), so the first consumer in namespace order decides
where the operator runs.

On ludo-kind-tls with a Certificate consumer in a namespace that sorts
before `cert-manager` (`aaa`), cert-manager lands in `aaa`, and
cluster-issuer's refusal advises moving the issuer to `aaa` rather than
declaring cert-manager in `cert-manager`.
