# kix/lib architecture

Index + the non-obvious bits. Read a file directly once you know where to go.

## Pipeline

```
flake.nix → mkFlake.nix → buildCluster (eval/cluster.nix)
  → evalModules (modules.nix)            # merge cluster config
  → auto-instantiate (eval/auto.nix)     # activate optionals + implicit deps
  → resolution index (eval/resolve.nix)  # DNS-like DI map
  → phase-1 pre-pass                     # introspect packages, inject config
  → nested fixpoint: evaluateInstance (eval/instance.nix)
      → scope (eval/scope.nix) → build() → collect → closure
      → netpol.processInstance, scorecard
  → aggregate manifests, stamp deps, build PackageInstance + Activation CRs
  → mkManifests → YAML dir
```

Entry points: `mkFlake` (flakes), `buildCluster` (raw), `mkEnv` (multi-env stamping).

## File index

| File | Role |
|---|---|
| `default.nix` | Re-exports everything. Start here to find a symbol. |
| `mkFlake.nix` | Flake boilerplate: runs `buildCluster`, wires `kixChecks`/`piChecks`. |
| `eval.nix` | Thin facade re-exporting `eval/*`. |
| `eval/cluster.nix` | `buildCluster` — the big orchestrator + fixpoint. |
| `eval/instance.nix` | `evaluateInstance` — one package → resources + PI CR. |
| `eval/resolve.nix` | DI resolution (DNS-like lookup, two-phase calling). |
| `eval/auto.nix` | Auto-instantiation of optional/implicit deps. |
| `eval/scope.nix` | Per-instance context: `mkDeployment/StatefulSet/DaemonSet`, capability checks, cross-ns validation. |
| `eval/namespace.nix` | `mkNamespace` (+ ResourceQuota, NetworkPolicy). |
| `eval/import.nix` | `mkImport` + lightweight PI for platform-provided services. |
| `eval/view.nix` | `mkPackageView` — public projection for CLI/registry. |
| `eval/helpers.nix` | `mergeCollide`, `collectTypedAttrs` (stops at `_type`). |
| `modules.nix` | NixOS module schema: `instances`, `namespaces`, `cluster.{provider,capabilities,network}`, `clusterLabels`, `scorecard`, `networkPolicy`, `globalPartsOverlays`. |
| `modules/` | Reusable cluster features (e.g. `monitoring.nix` auto-wires prometheus stack). |
| `flavors/` | Platform profiles: k3s, kind, kubeadm, eks, gke, gke-autopilot, aks, openshift, rke2, talos. Set capabilities, provide shadowable platform imports. |
| `k8s.nix` | `mkResource`, `mkImportResource`, `mkPackageInstance`, `mkActivation`, `mkSecretHelpers`, `attachCtxDeep`, `extractStoreHash`. The store-path-as-DAG machinery lives here. |
| `compose.nix` | `kixlib` passed to packages: `service.fromWorkload`, `ingress.fromService`, `httpRoute.fromService`, `mount.{pvc,configMap,secret,emptyDir}`, `withMounts[On]`, `expose`, `monitor`. |
| `helm.nix` | `fetchHelmChart`, `importChart` (IFD `helm template` → structured resource collection with get/find/byKind/workloads/mkParts + DAG linking), `helmChart` (Tier 1 inline convenience). Exposed to packages via `scope.helm`. |
| `crd.nix` | Pipeable CRD builders: `fromKind`, `clusterScoped`, `withShortNames`, `withSchema`. Instantiated via `scope.mkCRD`/`mkCRDRef`. |
| `netpol.nix` | Derives CiliumNetworkPolicy from store-path graph. `buildWorkloadCnps` (scope-level per-workload egress + self-ingress + caller-side paired ingress CNPs in the callee namespace via `scope.forNamespace`, runs inside `scope.mkDeployment` before the workload's `builtins.toFile` — workload ends up depending on all of its own CNPs via `extraDeps`), `processInstance` (post-fixpoint supplements: precise api-server egress via SA→Binding walk, LoadBalancer external-ingress, warnings), `generateDefaultDeny`. Every CNP is routed through the enforcer's `cnpCrdRef.out.cr` when one is declared, so the CNP → CRD marker → enforcer root edge falls out of DI automatically (see v2_discussions/83). There is no cluster-level inverted-ingress pass — Phase C eliminated it. |
| `rbac.nix` | Pipe DSL: `group`, `watch`, `reconcile`, `allow`, `restrictTo`, `sub`. |
| `scorecard.nix` | Rule engine. Levels: manifest/package/namespace/cluster. Severity override chain: rule disable → byOwner → byNamespace → rule → ruleDefaults. |
| `rules/` | Built-in rule library (security, reliability, governance, architecture). `architecture.nix` catches DI hygiene smells — packages hand-rolling resources that belong to another capability. |
| `meta.nix` | `peekPackageMeta` (introspect without building). |
| `env.nix` | `mkEnv` — stamp instance sets into env-prefixed namespaces. |
| `fragments.nix` | Small reusable manifest fragments. |

## Non-obvious patterns

- **Store-path = DAG edge.** Resources never declare deps explicitly. `mkResource` parses Nix string context on the manifest JSON and stamps `kix.dev/depends-on` annotations. The CLI later walks the store DAG (rooted at the Activation CR) to order deploys. → `k8s.nix`.
- **Manifests keep real names, not store paths.** Names in YAML are plain strings; store-path context rides alongside via Nix's context system. `attachCtxDeep`/`extractStoreHash` in `k8s.nix`.
- **Two-phase package calling.** Phase 1 (pre-fixpoint) introspects the function signature, resolves DI targets, and lets deps inject config (e.g. prometheus adds a ServiceMonitor). Phase 2 (inside `builtins.fix`) binds real instances via `ref` and calls `build`. → `eval/resolve.nix`, `eval/instance.nix`.
- **DNS-like DI.** Packages request deps by arg name (`{ vault, ... }`). Resolver: explicit override → same-namespace match → other-namespace (managed > import) → arg default → error. Aliases participate in the index. → `eval/resolve.nix`.
- **Platform imports are shadowable.** Flavors declare e.g. `platform-dns` via `kix.mkImport`. If the cluster installs its own coredns, the explicit instance wins. Breaks what would otherwise be circular build deps.
- **`self` convention.** Packages return resources in `self` with conventional names (`root`, `service`, `ingress`). Build functions may be a *list* of functions — later entries (e.g. `kix.expose`, `kix.monitor`) declare their own DI args, which the evaluator auto-discovers.
- **`_type` marker = leaf.** `collectTypedAttrs` stops descending when it sees `_type` (k8s-resource, k8s-import, etc.). That's how nested attrsets in `self` get flattened without eating the resources themselves.
- **`_kix.*` internal metadata.** Stripped before serialization. Used for cross-namespace validation (`_kix.namespace` on secret/volume refs), provenance (`_kix.source`), and reflected-secret markers.
- **Netpol is derived, not declared.** Egress policies come from the same store-path context used for dep ordering. Ingress policies are the inverse. StatefulSets get self-egress; RBAC/CRD presence opens API-server egress. Per-workload DNS + cross-package service egress CNPs are emitted *inside* `scope.mkDeployment/mkStatefulSet/mkDaemonSet` (before `builtins.toFile` runs on the workload), discovered by intersecting the raw spec's JSON string context against a Service registry built from the package's DI deps. The resulting CNPs are spliced into the workload's `extraDeps`, so the workload's own store-path context transitively includes its policies — closing the "unenforced window" without rebuilding the workload. Post-fixpoint signals (RBAC/CRD presence, LB Service detection) stay in `processInstance` as supplementary CNPs that depend on workloads the old way. The enforcer (`meta.provides ∋ "network-policy-enforcer"`) is auto-discovered at cluster level; each CNP is built via its `cnpCrdRef.out.cr` so the CNP → CRD marker → enforcer root edge is wired transitively. See v2_discussions/83.
- **Helm integration is lossy on purpose.** `importChart` strips helm.sh/meta.helm.sh annotations, `app.kubernetes.io/managed-by`, default `strategy` fields, and empty/test-hook resources so kix owns the labels/ordering cleanly. Configurable via `strip` + `preserveAnnotationPrefixes`.
- **Scorecard severity has a precedence chain**, not a flat config. Disable and per-owner/per-namespace overrides beat the rule's own severity, which beats `ruleDefaults`.
- **Capability ownership via `kix.dev/capability` annotation.** The `architecture.capabilityOwnership` rule detects hand-rolled resources that belong to another capability (e.g. PVCs outside a storage provider, reflector annotator bundles outside the reflector package). Capability owners declare `meta.provides = [ "storage" | "reflection" | … ]`. Consumers obtain the resources by declaring a DI dep arg and calling the owner's `out.*` builder — the builder stamps `kix.dev/capability: <name>` on every resource it returns so the rule treats them as DI-provided rather than hand-rolled. This is what lets a consumer scope (stackgres) host resources that belong to another capability (reflection) without tripping the rule. Fingerprints live in `rules/architecture.nix`; adding a new one is a data-only change.
- **Helm packages are real packages.** Helm-backed packages use `scope.helm.importChart` inside their `build` function and return `resources.mkParts { root = resources.get "Kind" "name"; out = { ... }; }`. DI builders, CRD refs, and meta.provides are declared inline — no special `rootOut`/`extraMeta` indirection. Three tiers: `kix.helmChart { ... }` (inline, Tier 1), `importChart` + `mkParts` (package, Tier 2), native (Tier 3). See v2_discussions/87.
- **`out` is the public surface of a resource.** `name`, `fqdn`, `selector`, `identityHash` are auto-derived and context-carrying; user `outputs = {...}` extend it. Always prefer `self.svc.out.name` over `"${self.svc}"` string interpolation.
- **Activation CR roots the closure.** `mkActivation` references every PackageInstance via string context so `nix-store -q --tree` on the Activation derivation yields the full deploy DAG. This is the contract the CLI relies on.

## Consumer shape (for context)

- **Cluster** (`clusters/*.nix`): `{ kix, packages }: kix.buildCluster { modules = [ kix.flavors.k3s { instances.ns.foo = { package = packages.foo; config = {...}; }; } ]; }`
- **Package** (`kix/packages/*/default.nix`): `{ scope, lib, kix, ... }: { options = {...}; build = { self, config, scope, kix, ... }: { root = scope.mkDeployment {...}; service = self.root |> kix.service.fromWorkload {...} |> scope.mkResource; }; }`
- **Flake**: `inputs.kix.lib.mkFlake { inherit inputs; clusters = { prod = ./clusters/prod.nix; }; }`

## When editing lib/

- Touching resource construction, context handling, or PI/Activation shape → you may or may not want to check `cli/` (reads the DAG).
- Touching module options or instance schema → update `modules.nix` types; packages consume via `config`.
- Adding a flavor/module → register in `default.nix` re-exports.
- If a change invalidates a "non-obvious pattern" above, update this file.
