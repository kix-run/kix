# kix/lib architecture

Internals map for editing the compiler. The tree is organized by ring: the deeper the ring, the higher the bar for changes. For authoring packages, read `guide/` instead.

## Layout by ring

```
core/     Ring 0: the artifact. Sealing, string-context machinery, and PackageInstance/Activation CRs.
eval/     Ring 1: the pipeline. Module eval, DI, fixpoints, edge analysis, hooks, and validation.
scope/    Ring 1: the authoring surface. Builders, validators, and labels.
vocab/    Open vocabulary: pure helper libraries, importable without the core.
plugins/  Ring 2: cross-cutting layers attached via hooks (netpol, availability).
```

Root files: `default.nix` (entry + YAML emission), `modules.nix` (option schema + hook options + plugin imports), `mkFlake.nix`, `meta.nix`, `env.nix`, `scorecard.nix`, `unsafe.nix`, `rules/`, `flavors/`, `modules/`, `helm.nix` + `helm-dag.nix`.

## Pipeline

```
flake.nix → mkFlake.nix → buildCluster (eval/cluster.nix)
  1. evalModules (modules.nix, imports plugins/netpol/module.nix + plugins/availability/module.nix)
  2. computeAutoInstances (eval/auto.nix)      # explicit wins
  3. namespaces: real vs sentinel (`_`-prefixed)
  4. resolution index (eval/resolve.nix)       # DNS-like DI map
  5. phase-1 pre-pass                          # introspect, resolve dep targets, config injections
                                               # (`ref.<ns>.<inst>` is a static pointer built over
                                               # every name step 2 could produce)
  6. instanceConfigs fixpoint                  # config-only; breaks function-injection cycles
  7. clusterInstances fixpoint: evaluateInstance (eval/instance.nix)
       mkScope (scope/) → build entries folded with `mergeCollide` (parts fixpoint + overlays)
       → sealWorkload: edges → dnsDeps → workloadInterceptors → podSpec merge + pre-seal requires splice
       → collect → closure diagnostics → instanceProcessors → PI CR → view
  8. clusterProcessors (default-deny, platform intents, scrape policies, enforcer assertions)
     → aggregate, Activation CR, package index, extraImages
  → mkManifests → YAML dir (default.nix)
```

## File index

| File | Role |
|---|---|
| `core/resource.nix` | `mkResource` (sealing via `builtins.toFile` over manifest JSON + folded dependency context), `mkImportResource`, `out.*` derivation, tagged `kix.run/depends-on` (bare / `requires:` / `extra:`), fact minting/forwarding/stripping at the seal boundary, `attachCtxDeep`, `extractStoreHash`, `stripKixMeta`, `mkSecretHelpers`, `kixCRDs`, `mkCRDBuilders`, `mkImportMarker`, and `mkCRDRefHandle`. |
| `core/version.nix` | Version grammar `[v]N(.N)*[-suffix][+build]`, `compare`, and tri-state `atLeast`/`atMost` that compare at the constraint's precision and return null for an unknown version. |
| `core/normalize.nix` | Collapse-rule manifest normalization: nulls stripped bottom-up, all-null containers collapse to absent, literal empties render. `keep` (exported as `kix.keep`) marks a container so it never collapses; `resolveKeeps` resolves markers at the `mkResource` boundary; `normalizeManifest` runs at YAML generation. |
| `core/markers.nix` | Inert string-context markers: `mkUntrackedRef` (`kix.untrackedRef`) and `mkProvidedLoadBalancerClass` (`kix.providedLoadBalancerClass`). Carries expectation metadata (`readExpectation`, `selfCreatedNames`, `isMarkerPath`) without adding deploy-graph edges. |
| `core/facts.nix` | Typed facts: dependency-free `toFile` tokens carried alongside derivation store paths. `mkFact`, `partitionCtx`/`stripFacts`, `readFact`/`factsOfKind`, `terminatorKinds`, and user escapes `refOnly`, `connect`, and `structural`. |
| `core/annotations.nix` | Canonical Kix annotation and label keys (`domain`, `group`, `apiVersion`, `keys`, `values`, `legacyDomains`), exposed as `kix.keys` and `kix.keyValues`. Paired with `cli/kix/src/manifest/keys.rs`. |
| `core/activation.nix` | `mkPackageInstance` (lifecycle, inverse dependencies, post-hooks) and `mkActivation` (closure root and CLI contract). |
| `core/availability.nix` | Availability levels (`levels`, `rank`, `atLeast`, `pick`, `substrate`, `checkCeiling`, `ceilingOfMeta`, `underCeiling`, `spreadConstraints`, `resolve`). Exposed to packages as `kix.availability.*`. |
| `eval/cluster.nix` | `buildCluster`: the three fixpoints, hook execution, scorecard and cross-resource diagnostics, and Activation aggregation. |
| `eval/instance.nix` | `evaluateInstance`: DI binding, availability resolution, `packageKix`, parts fixpoint, overlays, `_injectedResources` drain, `instanceProcessors`, and diagnostics. |
| `eval/resolve.nix` | Resolution index, `resolveArg` ladder, `refsOf`, `checkRefTargets`, phase-1 package calling, `buildEntriesOf`, config injections, `mkLocked`, and `evaluateInstanceConfig`. |
| `eval/auto.nix` | Auto-instantiation over `availablePackages` via `genericClosure` over demanded dependencies and optional instances, plus `possibleInstanceNames` and `spreadRefusals`. |
| `eval/roles.nix` | Role registry (`network-policy-enforcer`, `dns`, `storageClasses`, `snapshotController`, `metricsApi`, `registryMirror`, `cni`, `loadBalancer`), `out` contract checks, and binding modes (`absent`, `shadowable`, `exclusive`). |
| `eval/edges.nix` | Edge analysis on typed facts (`analyzeEdges`): reads endpoint facts from workload string context, pairs with `serviceIndex`, and feeds DNS dependency injection and the netpol plugin. |
| `eval/validate.nix` | `crossResourceFailures { manifests, identityHashes, owners, externalNames }`: cross-resource validation over rendered, context-free manifests. Delegates CRD/namespace checks to `eval/validate-crds.nix` and Secret/ConfigMap key checks to `eval/validate-keys.nix`. |
| `eval/validate-crds.nix` | Checks 18 and 21 of `crossResourceFailures`: validates that namespaced kinds have `metadata.namespace` and that custom resources depend on a CRD, CRD ref, or APIService serving their group, kind, and version. |
| `eval/validate-keys.nix` | Check 22 of `crossResourceFailures`: validates that workload `env`, volume `items`, and `subPath` mounts reference keys declared on their target Secret or ConfigMap. |
| `eval/options.nix` | Option contract checker (`optionContractViolations`, `checkOptionContract`): verifies that package options do not use untyped or `attrsOf` non-empty defaults that an instance override would partially discard. |
| `eval/package-options.nix` | `checkPackageOptions` and `packageOptionViolations`: runs the option contract across a package's phase-1 options at each availability level up to `meta.availability.max`. |
| `eval/instance-pins.nix` | Applies `kix.pins` instance overrides, checks pin priority conflicts, and builds `kix-image-sources.json` provenance metadata. |
| `eval/hooks.nix` | `buildRolesIndex`/`findRoleProvider`, `checkRoleBindings`, `buildAnnotationDomainIndex`, `collectHooks` (priority-sorted and shape-validated), and `runChecks`. |
| `eval/consumers.nix` | Multi-team platform/consumer interface generation (`platform`), loading (`interface`), and namespace/quota enforcement (`consumer`). |
| `eval/pod-security.nix` | `violations level manifest`: checks workload pod templates against Kubernetes Pod Security Standards (`baseline`, `restricted`). |
| `eval/import.nix` | `mkImport`, `mkImportScope`, `evaluateImportInstance`, and `resolveExtraDep` for externally managed resources and platform imports. |
| `eval/namespace.nix` / `view.nix` / `helpers.nix` | `mkNamespace`, `mkPackageView`, and shared traversal/merge helpers (`collectTypedAttrs`, `mergeCollide`). |
| `scope/default.nix` | `mkScope`: assembles labels, validators, and builders into the package `scope` object, plus `forNamespace` and `forService` subscopes. |
| `scope/builders.nix` | Resource builders and the `sealWorkload` pipeline (edge analysis, DNS dependency injection, `workloadInterceptors`, `podSpec` merging, pre-seal `requires` splicing, and `_injectedResources` attachment). |
| `scope/validators.nix` | Spec-level validators: cross-namespace references, selector subset, ports, resources, capability/role gates (`checkLoadBalancer`, `requireMetricsApi`), `checkRawPvc`, and `checkResourceName`. |
| `scope/labels.nix` | Standard label generation (`kix` and `helm` styles, selector labels). |
| `plugins/netpol/module.nix` | Declares `networkPolicy.*` options and registers `workloadInterceptors`, `instanceProcessors`, and `clusterProcessors` hooks. |
| `plugins/netpol/derive.nix` | Network policy derivation from `ctx.edges`: per-workload egress and self-ingress, caller-side ingress, API server egress, LoadBalancer ingress, default-deny, and platform intents. |
| `plugins/netpol/scrape.nix` | Derives scrape egress and ingress policies by joining scrapers (Prometheus and VMAgent CRs) with the scrape objects they select: ServiceMonitors, PodMonitors, VMServiceScrapes, VMPodScrapes, the operators' own scrape objects from `factBehavior.selfScrapes`, and Alertmanager endpoints. |
| `plugins/netpol/interface.nix` | Network policy enforcer contract (`out.netpol`). |
| `plugins/availability/module.nix` | Declares `cluster.availability.*` and `cluster.topology.*` options; injects `topologySpreadConstraints`, derives PodDisruptionBudgets, and enforces replica/ceiling invariants. |
| `vocab/default.nix` | Assembles the public `kix.*` helper library from the `vocab/` modules, `core/availability.nix`, and `scorecard.nix`. |
| `vocab/compose.nix` | Core composition helpers (`image`, `port`, `mkEnvVars`, `mkEnv`, `mergeGuarded`, `mergeEnv`, `guardArgs`, `checkSecretKeys`, `operandPolicy`, `service.*`) and re-exports of the split `vocab/` modules. |
| `vocab/expose.nix` | `ingress`, `httpRoute`, `gatewayPathType`, and `expose` (Gateway API HTTPRoute / Ingress routing, `exposure` URL resolution, and ingress-controller/gateway network policy edges). |
| `vocab/mounts.nix` | Volume mount constructors (`kix.mount.{pvc,configMap,secret,emptyDir,hostPath}`) and workload injection (`withMounts`, `withMountsOn`). |
| `vocab/options.nix` | Reusable package option schemas (`kix.options.{image,resources,env,ingress,monitor,healthCheck}`). |
| `vocab/health-check.nix` | `kix.healthCheck`: builds post-deploy probe Jobs and script ConfigMaps. |
| `vocab/monitor.nix` | `kix.monitor` and `kix.alerts`: builds `ServiceMonitor` and `PrometheusRule` parts. |
| `vocab/contract.nix` | Shared `mkContract` builder for provider `check` and consumer `problems` / `assertions` / `require` validators. |
| `vocab/gateway.nix` | `kix.contracts.gateway`: Gateway provider/consumer contract (`gatewayRef`, `listeners`, `podSelector`, `podNamespace`). |
| `vocab/oidc-provider.nix` | `kix.contracts.oidcProvider` and `kix.options.oidc`: OpenID Connect provider contract (`issuerUrl`, `endpoints`), `requireClient`, and consumer option schema. |
| `vocab/otlp-endpoint.nix` | `kix.contracts.otlpEndpoint`: OTLP receiver contract (`otlpGrpcUrl`, `otlpHttpUrl`, `tls`). |
| `vocab/postgres-database.nix` | `kix.contracts.postgresDatabase`: PostgreSQL database contract (`host`, `port`, `database`, `credentials`, `username`, `extensions`, `tls`). |
| `vocab/pins.nix` | `kix.pins`: loads and validates committed JSON pin files. |
| `vocab/quantity.nix` | Kubernetes quantity grammar (`kix.types.quantity`) and parser (`kix.parseQuantity`). |
| `vocab/quota-use.nix` | The least a namespace's objects use of its ResourceQuota, from built-in pod kinds and CRD `usesAtLeast` declarations; `buildCluster` refuses a build whose least use is over a quota. |
| `vocab/storage-class.nix` | `kix.types.storageClass` and `kix.storage.mkClasses` for StorageClass provider packages. |
| `vocab/durations.nix` | Prometheus duration type/helpers (`kix.types.promDuration`, `kix.durations.*`) and cron staleness helper (`kix.schedules.staleAfter`). |
| `vocab/rbac.nix` / `crd.nix` / `fragments.nix` | Pipeable RBAC and CRD builders, and multi-file cluster fragment merging. |
| `modules.nix` | Cluster option schema, `hooks.*` options, and plugin module imports. |
| `tests/` | Evaluation regression suite (`nix eval --extra-experimental-features 'nix-command flakes pipe-operators' --impure --expr '(import ./kix/lib/tests { }).result'`). |

## The hook contract

Plugins attach through three module options. A hook is a function `ctx → result` or `{ priority ? 1000; fn; }`. Execution order is `(priority ascending, then name)`. Results are shape-checked per channel in `eval/hooks.nix`.

- `hooks.workloadInterceptors.<name> :: ctx → { requires?, resources?, warnings?, podSpec? }`: runs inside `sealWorkload` before `builtins.toFile` seals the workload. `requires` splice pre-seal; `resources` ride the `_injectedResources` sideband and are drained after the parts fixpoint; `podSpec` is merged into `spec.template.spec` per top-level field (author fields win; earlier hook wins between hooks).
- `hooks.instanceProcessors.<name> :: ctx → { resources?, warnings? }`: runs post-parts-fixpoint per instance.
- `hooks.clusterProcessors.<name> :: ctx → { resources?, checks?, warnings? }`: runs at cluster aggregation. `resources` become Activation `extraDeps` and the manifest-list tail in hook execution order. Each entry in `checks` is a lazy value forced before the cluster result is returned.

**Hooks emit through `ctx.emit`, never a scope.** The facade (`scope/builders.nix`) provides sealing capability only (`mkResource`, `mkClusterResource`, `inNamespace nsName → { mkResource }`).

Fixpoint safety: a hook may read `workloadInput` and outer-fixpoint data (DI deps, cluster config); it must not force the resource under construction, and returned resources must not close a cycle into the current parts fixpoint.

## Key patterns

- **Store-path = DAG edge.** Resources never declare dependencies explicitly; `mkResource` reads Nix string context off the manifest JSON and stamps `kix.run/depends-on`. The CLI walks the store DAG rooted at the Activation CR (`core/resource.nix`).
- **Two context channels: identity and facts.** Identity paths record derivation lineage ("computed from X") and drive deploy ordering. Fact tokens (`core/facts.nix`) are dependency-free claims ("dialing this value's target reaches selector S on ports P") minted on address-shaped `out` fields, conducted through non-workload resources, terminated at workloads where `eval/edges.nix` projects them into network-policy edges and DNS dependencies, and stripped before `builtins.toFile`.
- **Terminate vs. conduct.** Core Kubernetes workload kinds are hardcoded in `facts.terminatorKinds`. CRD kinds declare `factBehavior` (`terminate` or `conduct`, plus `podSelector`), `readiness`, `usesAtLeast`, and `holdsData` on `scope.mkCRD` / `scope.mkCRDRef`, which thread through `mkCRDBuilders` to every CR built via `scope.mkCR`. `mkResource` writes `holdsData` as `kix.run/holds-data`, deciding it for built-in kinds from the manifest's shape (`holdsDataOf`), and `buildCluster` refuses a stateful package's custom resources that carry none (`holdsDataAssertions` in `eval/cluster.nix`). Cluster operators can override per kind via `cluster.factBehavior."<group>/<Kind>"`.
- **Sealing is one-way.** After `builtins.toFile`, a resource's identity is fixed. Anything that influences a workload's dependency list must run in the pre-seal pipeline.
- **Three fixpoints.** Phase-1 pre-pass (introspection), config-only fixpoint (allows function-shaped dependency injections to read consumer config without cycling), and full instance fixpoint (`eval/cluster.nix`).
- **DNS-like DI.** Explicit override (`ref` or list of `ref`s) → managed-over-import filter → unique same-namespace → unique other-namespace → argument default → throw (`eval/resolve.nix`).
- **Roles.** `meta.roles` (validated against `eval/roles.nix`) drives the provider index, DI aliasing, and binding-mode checks.
- **Object names are checked during evaluation.** `scope/validators.nix#checkResourceName` enforces RFC 1035 labels for Services, DNS-1123 labels for Namespaces, and DNS-1123 subdomains for other non-RBAC resources.
- **Capability ownership.** `meta.unsafe` (`unsafe.nix`) gates raw PVCs (`raw-pvc`) and security exemptions (`host-network`, `privileged`, `run-as-root`, `cluster-admin`). Operator packages declare `meta.annotationDomains`, which `architecture.annotationDomainOwnership` checks against resource annotations.
- **Secrets carry provenance.** `mkSecret` stamps `kix.run/{secret-keys,secret-sources,sops-source,content-hash,...}`; `mkSecretRef` and `mkServiceRef` emit `PackageInstance` import markers (`scope/builders.nix`).
- **Ceded fields.** `ownership.cede` on `mkResource` / `mkCRD` stamps `kix.run/cede-fields` so the CLI (`cluster/apply.rs`) preserves controller-managed fields on apply.
- **Scorecard evaluation.** Enabled by default and capped at `scorecard.maxSeverity` (`warning` by default; `error` in this repository's flakes via `mkFlake { clusterModules }`). Manifest and package rules run over both authored parts and processor-derived resources (`eval/instance.nix`), and cluster/namespace findings feed into `collectClusterDiagnostics` (`eval/cluster.nix`).
- **Committed pins.** Values decided outside the compilation unit live in a committed JSON pin file (`kix.pins`, applied per instance by `eval/instance-pins.nix` and provenance-tracked in `kix-image-sources.json`).
- **`parts.root` is an alias, not a standalone resource.** `collectResources` excludes the `root` key; packages must alias `root` to a named part (`root = self.service`).

## When editing lib/

- `core/` changes touch the CLI contract (Activation closure, `depends-on` format, and `PackageInstance` fields); coordinate with `cli/`.
- `core/annotations.nix` and `cli/kix/src/manifest/keys.rs` move together; retiring a domain requires an entry in `cli/kix/src/legacy_domain/`.
- Authoring-surface changes (scope builders, vocab, DI semantics) → update `guide/` and the `kix-migration` skill.
- New cross-cutting concerns belong in plugins registering hooks rather than inline calls in `eval/` or `scope/`.
- Refactors must keep the manifest store path identical on `nix build ludo/#cluster-ludo-kind`; intentional output changes ship separately.
- If a change invalidates a pattern above, update this file.
