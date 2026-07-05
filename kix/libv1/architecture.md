# kix/lib architecture

Internals map for editing the compiler. Index + the non-obvious bits; read a file directly once you know where to go. For *authoring packages*, read `guide/` instead — it is the user-facing reference and stays closer to the API surface.

## Pipeline

```
flake.nix → mkFlake.nix → buildCluster (eval/cluster.nix)
  1. evalModules (modules.nix)                 # merge cluster config; ref thunks stay lazy
  2. computeAutoInstances (eval/auto.nix)      # auto-instantiate deps + activate optionals; explicit wins
  3. namespaces: real vs sentinel (`_`-prefixed keys, e.g. `_cluster`)
  4. resolution index (eval/resolve.nix)       # DNS-like DI map from static meta + aliases
  5. netpol enforcer lookup                    # meta.provides ∋ "network-policy-enforcer", ≤1,
                                               # validated against netpol-interface.nix
  6. phase-1 pre-pass (eval/resolve.nix)       # introspect packages, resolve dep targets,
                                               # collect config injections
  ── three fixpoints ──
  7. instanceConfigs fixpoint                  # config-only eval; lets function-shaped
                                               # injections read consumer config without cycling
  8. clusterInstances fixpoint: evaluateInstance (eval/instance.nix)
       scope (eval/scope.nix) → build entries folded (parts fixpoint + overlays)
       → collect → closure + orphan/inverse-dep detection
       → netpol.processInstance, scorecard, mkPackageInstance, mkPackageView
  9. aggregate: resources, platform intents, default-deny, cluster scorecard,
     Activation CR, package index JSON, extraImages
  → mkManifests → YAML dir (default.nix)
```

Entry points: `mkFlake` (flakes), `buildCluster` (raw), `mkEnv` (multi-env stamping).

## File index

| File | Role |
|---|---|
| `default.nix` | Re-exports everything + `mkManifest(s)` YAML serialization. Start here to find a symbol. |
| `mkFlake.nix` | Flake boilerplate: runs `buildCluster`, wires `kixChecks`/`piChecks`, emits scorecard JSON + `kix-extra-images.json`. |
| `eval.nix` | Wiring facade: imports `eval/*`, threads deps, re-exports. |
| `eval/cluster.nix` | `buildCluster` — orchestrator, three fixpoints, enforcer plumbing, aggregation. |
| `eval/instance.nix` | `evaluateInstance` — one package → resources + PI CR; parts fixpoint, overlays, closure diagnostics. |
| `eval/resolve.nix` | DI resolution index, `resolveArg`, phase-1 calling, config injections, `mkLocked`. |
| `eval/auto.nix` | Auto-instantiation of required/optional deps via `genericClosure` over `availablePackages`. |
| `eval/scope.nix` | Per-instance context: `mkDeployment/StatefulSet/DaemonSet/Job/HelmWorkload`, `mkOptional`, `mkWebhookService`, `mkCRD/mkCRDRef/mkCR`, `mkSecret/mkSecretRef/mkServiceRef`, `labels.*`, edge forwarding (`augmentEdge`, `forwardEdges`), `forNamespace`/`forService` subscopes, capability gates, cross-ns + selector/probe/limits validation. |
| `eval/namespace.nix` | `mkNamespace` (+ ResourceQuota, NetworkPolicy). |
| `eval/import.nix` | `mkImport` + lightweight PI for platform-provided services; materializes platform intents. |
| `eval/view.nix` | `mkPackageView` — public projection for CLI/registry. |
| `eval/helpers.nix` | `mergeCollide`, `collectTypedAttrs` (stops at `_type`, maxDepth 3). |
| `modules.nix` | Module schema: `instances` (per-instance: aliases, deps, partsOverlays, labelStyle, platformIntents, optional, …), `namespaces`, `availablePackages`, `autoNamespace`, `global`, `k8sVersion`, `clusterDomain`, `clusterLabels`, `cluster.{provider,capabilities,network,nodes,maintenance}`, `scorecard`, `networkPolicy`, `globalPartsOverlays`. |
| `modules/` | Reusable cluster features. Currently: `monitoring.nix` (wires the native prometheus stack). |
| `flavors/` | Platform profiles: k3s, kind, kubeadm, eks, gke, gke-autopilot, aks, openshift, rke2, talos, scaleway, ovh, lithus. Set provider + capabilities, provide shadowable `platform-dns`/`platform-storage` imports. `lithus` is the outlier: extends rke2 and provisions concrete OpenEBS/Mayastor storage resources. |
| `k8s.nix` | `mkResource`, `mkImportResource`, `mkPackageInstance`, `mkActivation`, `mkSecretHelpers`, `attachCtxDeep`, `extractStoreHash`, `stripKixMeta`. The store-path-as-DAG machinery lives here. |
| `compose.nix` | `kixlib` passed to packages as `kix`: `service.fromWorkload`, `ingress.fromService`, `httpRoute.fromService`, `mount.{pvc,configMap,secret,emptyDir,hostPath}`, `withMounts[On]`, `expose`, `monitor`, `untrackedRef`. |
| `helm.nix` | `fetchHelmChart`, `importChart` (IFD `helm template` → structured collection + DAG linking), `importChartCrds` (CRD-only templating), `helmChart` (Tier 1 inline). Exposed via `scope.helm`. |
| `helm-dag.nix` | Pure inference of intra-chart resource deps from well-known K8s patterns (SA mounts, volumes, envFrom, RBAC, Service selectors, HPA/PDB targets, Ingress/HTTPRoute backends, ServiceMonitor selectors). Runs on raw JSON pre-wrapping; edges become `requires`. |
| `netpol.nix` | Derives network policies from the store-path graph: `buildWorkloadCnps`, `processInstance`, `generateDefaultDeny`, intent translation, ServiceRef registry, DNS dep injection. |
| `netpol-interface.nix` | The pluggable enforcer contract: required `out.netpol` functions + `validateEnforcerInterface`, `materializePlatformIntent`. Anticipates Cilium, Calico, native NetworkPolicy backends. |
| `crd.nix` | Pipeable CRD builders: `fromKind`, `clusterScoped`, `withVersion/ShortNames/Categories/PrinterColumns/Schema/Labels/Annotations`. Instantiated via `scope.mkCRD`/`mkCRDRef`. |
| `rbac.nix` | Pipe DSL: `group`, `restrictTo`, `sub`, intents (`watch`, `reconcile`, `finalize`, `own`, `readWrite`, `full`, `emit`, `allow`), `grant`. |
| `scorecard.nix` | Rule engine. Levels: manifest/package/namespace/cluster. Error findings become build-blocking assertions; warnings become trace output. |
| `rules/` | Built-in rules (security, reliability, governance, architecture). `architecture.nix` catches DI hygiene smells: `capabilityOwnership`, `selectorCoherence`, `fqdnWithoutContext`. |
| `meta.nix` | `peekPackageMeta` (introspect without building), diagnostics/warnings engine, version compat checks. |
| `env.nix` | `mkEnv` — stamp instance sets into env-prefixed namespaces. |
| `fragments.nix` | `mergeFragments` — combine per-team `{namespaces, instances}` fragments with collision detection. |

## Non-obvious patterns

- **Store-path = DAG edge.** Resources never declare deps explicitly. `mkResource` parses Nix string context on the manifest JSON and stamps `kix.dev/depends-on` annotations (tagged: bare hash = interpolation, `requires:<hash>`, `extra:<hash>`). The CLI walks the store DAG rooted at the Activation CR to order deploys. → `k8s.nix`.
- **Manifests keep real names, not store paths.** Names in YAML are plain strings; store-path context rides alongside via Nix's context system. `attachCtxDeep`/`extractStoreHash` in `k8s.nix`.
- **Three fixpoints, not one.** Phase 1 (plain pre-pass) introspects signatures, resolves DI targets, collects config injections. The config-only fixpoint (`instanceConfigs`) exists solely so function-shaped injections can read consumer config without cycling. The full fixpoint (`clusterInstances`) binds real instances and calls `build`. → `eval/cluster.nix`.
- **DNS-like DI.** Packages request deps by arg name (`{ vault, ... }`). Resolution: explicit override → filter managed-over-import → unique same-namespace match → unique other-namespace match → arg default → error. Ambiguity (>1 candidate at a step) is a hard throw; aliases participate in the index. Import shadowing happens here: a managed instance beats a `mkImport` with the same name. → `eval/resolve.nix`.
- **`mkLocked`** lets cluster authors freeze config fields; a dep injection targeting a locked key throws with source attribution. → `eval/resolve.nix`.
- **Sentinel namespaces.** `_`-prefixed instance keys (e.g. `_cluster`) evaluate normally but emit no Namespace/quota/netpol and skip namespace scorecard. → `eval/cluster.nix`.
- **`self` convention.** Packages return resources in `self` with conventional names (`root`, `service`, `ingress`). `build` may be a *list* of entries (functions or paths) — later entries (e.g. `kix.expose`, `kix.monitor`) declare their own DI args, auto-discovered by the evaluator. Overlays (`globalPartsOverlays` + per-instance `partsOverlays`) are applied inside the same parts fixpoint. → `eval/instance.nix`.
- **`_type` marker = leaf.** `collectTypedAttrs` stops descending when it sees `_type` (k8s-resource, k8s-import, …). That's how nested attrsets in `self` flatten without eating the resources.
- **`_kix.*` internal metadata.** Whitelisted keys (`namespace`, `source`, `reflected`, `serviceAccountNamespace`), stripped by `stripKixMeta` before serialization; used for cross-namespace validation and provenance.
- **Netpol is derived, not declared — and the enforcer is pluggable.** Egress comes from the same store-path context used for dep ordering. Per-workload CNPs (egress, self-ingress, caller-side ingress in the callee namespace via `scope.forNamespace`) are emitted *inside* `scope.mkDeployment/mkStatefulSet/mkDaemonSet/mkJob/mkHelmWorkload` before `builtins.toFile`, and spliced into the workload's `extraDeps` so the workload transitively depends on its own policies. Post-fixpoint `processInstance` adds supplements only (precise api-server egress via SA→Binding walk, LoadBalancer external-ingress, warnings) — there is no cluster-level inverted-ingress pass. Rule *shape* is delegated to the enforcer's `out.netpol.mkPolicy`; the enforcer is discovered via `meta.provides ∋ "network-policy-enforcer"` and validated against `netpol-interface.nix`. Declarative intents (`world`/`dns`/`apiserver`/`all-pods`) and flavor-level `platformIntents` (policies for non-kix pods like CoreDNS) translate through the same interface. See v2_discussions/83, 92.
- **DNS dep injection is unconditional.** Workloads referencing cross-instance Services get the DNS root as an extra dep even when `networkPolicy.enable = false`. → `netpol.nix`.
- **Secrets carry provenance.** `scope.mkSecret` realizes a `source` file (e.g. SOPS) as its own store path via `builtins.path` and stamps `kix.dev/{secret-keys,sops-source,content-hash,classification,rotation-policy}`. `mkSecretRef`/`mkServiceRef` emit PackageInstance import markers polled at deploy time; `reflect = true` marks `_kix.reflected` to bypass the cross-ns check. → `eval/scope.nix`, `k8s.nix`.
- **Helm integration is lossy on purpose.** `importChart` strips helm.sh/meta.helm.sh annotations, `managed-by`, default `strategy`, and test hooks (configurable via `strip.{helmAnnotations,helmLabels,defaultStrategy}` + `preserveAnnotationPrefixes`). Chart workloads route through `scope.mkHelmWorkload` so they get per-workload CNPs like native ones. Values-JSON string context is discarded so renders cache on chart+values only. Three tiers: `kix.helmChart` (inline), `importChart` + `mkParts` (package), native. See v2_discussions/87.
- **Helm collections are rich.** `importChart` returns `get/find/byKind/workloads/all/excluding/depsOf/edges/orphans/crds/autoRoot/replaceResource/patchResources/mkParts`, auto-derives `crds.<Kind>.{cr,mkCR}` builders (consumer CRs gate on CRD establishment + chart workloads), and accepts `deps`/`networkDeps`/`extraEdges` for cross-package wiring. → `helm.nix`.
- **Scorecard severity precedence** (most specific wins): byRule disable → byRule severity → byOwner → byNamespace → rule's own severity → `ruleDefaults`. All overrides live under one `scorecard.ruleOverrides` attr. Error-level findings block the build.
- **Capability ownership via `kix.dev/capability` annotation.** `architecture.capabilityOwnership` detects hand-rolled resources that belong to another capability (PVCs outside a storage provider, reflector bundles outside the reflector package). Owners declare `meta.provides`; consumers get resources via a DI arg + the owner's `out.*` builder, which stamps the annotation. Fingerprints in `rules/architecture.nix` are data-only additions.
- **`out` is the public surface of a resource.** `name`, `fqdn`, `selector`, `identityHash` are auto-derived and context-carrying; user `outputs` extend it (`null` suppresses a derived field). Services get `out.url { scheme?, port? }` and `out.ports`. Prefer `self.svc.out.name` over `"${self.svc}"`.
- **Context escape hatches are deliberate and visible.** `workload.rawSelector` exposes raw `matchLabels` without forcing the workload's context (sibling-cycle escape; `architecture.selectorCoherence` fires to keep it visible). `kix.untrackedRef` is the generic name-without-edge variant; `architecture.fqdnWithoutContext` catches hand-written `*.svc` strings.
- **Activation CR roots the closure.** `mkActivation` references every PackageInstance via string context, so the Activation derivation's store tree is the full deploy DAG. PI CRs carry `lifecycle` (stateful/durable/ephemeral), inverse deps, and post-hooks. This is the contract the CLI relies on.

## When editing lib/

- Touching resource construction, context handling, or PI/Activation shape → check `cli/` (reads the DAG).
- Touching the authoring API surface (scope builders, `kix.*` helpers, DI semantics) → update `guide/` (it cites lib files as authority) and the `kix-migration` skill.
- Touching module options or instance schema → update `modules.nix` types; packages consume via `config`.
- Adding a flavor/module → register in `default.nix` re-exports.
- If a change invalidates a "non-obvious pattern" above, update this file.
