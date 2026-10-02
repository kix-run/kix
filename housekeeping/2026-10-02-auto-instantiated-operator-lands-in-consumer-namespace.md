# 2026-10-02 · `kix/lib/eval/auto.nix` · An auto-instantiated cluster-scoped operator lands in the namespace of the first package that needs it.

A cluster with `immich` and a `stackgres-database` but no `stackgres-operator`
instance gets the operator's Deployment, ServiceAccount, Service, and CRD
markers in immich's namespace (trace: `auto-instantiated: ...,
stackgres-operator (photos)`). The operator then shares its lifecycle with one
app. The `immich` package header asks users to declare `stackgres-operator`
once in its own namespace; nothing enforces that.

- Hit again 2026-10-02 in the W6 ludo-kind-tls kind run (K3). A package in
  namespace `probe` that names `certManager` got a second, auto-instantiated
  cert-manager in `probe`, beside the one the `selfsigned` cluster-issuer had
  pulled into `cert-manager`. The build failed with "annotation domain
  'cert-manager.io' is declared by two instances: cert-manager/cert-manager
  and probe/cert-manager". Wiring `deps.certManager = ref.cert-manager.cert-manager`
  worked. Any app that builds a Certificate from `certManager.out.crds` in its
  own namespace hits this unless cert-manager is declared explicitly.
