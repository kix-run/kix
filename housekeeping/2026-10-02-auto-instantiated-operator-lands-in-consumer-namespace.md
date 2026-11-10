# 2026-10-02 · `kix/lib/eval/auto.nix` · An auto-instantiated cluster-scoped operator lands in the namespace of the package that needs it.

A cluster with `immich` and a `stackgres-database` but no `stackgres-operator`
instance gets the operator's Deployment, ServiceAccount, Service, and CRD
markers in immich's namespace (trace: `auto-instantiated: ...,
stackgres-operator (photos)`). The operator then shares its lifecycle with one
app. The `immich` package header asks users to declare `stackgres-operator`
once in its own namespace. Kix enforces that only when consumers in two
namespaces need a package marked one per cluster (`spreadRefusals`); a single
consumer namespace still gets the operator.

A role-named dependency is keyed by the role, so its provider lands in the
namespace of the first requester in closure order, and consumers in other
namespaces bind to that copy without an error.
- 2026-11-10: Kix now warns when it places a once-per-cluster package beside its only consumer, and 0.10 will refuse it. Delete this entry when the warning becomes an error.
