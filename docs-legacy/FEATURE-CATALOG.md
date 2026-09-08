# kix Feature Catalog

Complete inventory of kix/lib (Nix library) and CLI features. Breadth-first — every capability mentioned, none deeply explained.

---

## kix/lib — Nix Library

### Core Resource System (`k8s.nix`)

- **`mkResource`** — Content-addressed K8s resource constructor. Accepts apiVersion, kind, name, namespace, spec, data, stringData, labels, annotations, outputs, requires, extraDeps, extra, clusterDomain. Auto-derives selector from `spec.selector.matchLabels` or labels. Auto-derives outputs: name, fqdn, identityHash, selector. Stamps `kix.dev/depends-on` annotation from dependency graph. Returns resource with `outPath` (Nix store path), `out`, `rawManifest`, `manifest`.
- **`mkClusterResource`** — Same as mkResource but cluster-scoped (no namespace).
- **`mkImportResource`** — Lightweight ref constructor for import mode (no store paths).
- **`clusterScoped`** — Sentinel value for cluster-scoped resources.
- **`mkPackageInstance`** — PackageInstance CR: root of per-package DAG. Carries root resource ref, requires, post-hooks, inverse deps, version.
- **`mkActivation`** — Cluster-level root CR referencing all instances via Nix string context.
- **`mkCRDBuilders`** — Generates `cr` (transformer) and `mkCR` (builder) for custom resource types.
- **`attachCtxDeep`** — Recursively attach Nix string context to all strings in a tree (implicit dependency tracking).
- **`extractStoreHash`** — Extract 32-char hash from `/nix/store` path.
- **`nsOf`** — Resolve resource namespace to string key.
- **`resourceId`** — Canonical ID: `"${kind}/${name}@${namespace}"`.
- **`kixCRDs`** — Built-in CRD resources (PackageInstance, Activation).

### Cluster Evaluation (`eval.nix`, `eval/`)

- **`buildCluster`** — Top-level orchestrator. Evaluates NixOS modules, auto-instantiates packages, resolves DI, builds fixpoint, collects resources, generates activation.
- **Auto-instantiation** (`eval/auto.nix`) — Transitive closure via `builtins.genericClosure` from mandatory deps. Seeds from explicit instances, discovers transitively required packages. Handles optional vs. available packages.
- **Dependency injection** (`eval/resolve.nix`) — DNS-like resolution: explicit override > same-namespace > cluster-wide > default. Managed instances preferred over imports.
- **`callPackagePhase1`** — Calls package with system args (scope, lib, kix).
- **`discoverBuildDeps`** — Introspects build function args for DI dependency names.
- **`resolveDeclaredDeps`** — Resolves declared deps via resolution index.
- **`resolveDepTargets`** — Phase-1 pre-pass: resolve targets without full evaluation.
- **`buildConfigInjections`** — Creates NixOS module injections from dep phase-1 results.
- **`evaluateInstanceConfig`** — Evaluates config via `lib.evalModules`. Deep-merges option defaults. Supports `mkLocked` for immutable fields. Detects conflicts with dep injections.
- **`mkLocked`** — Marks a config field as immutable (blocks dep injection overrides).
- **`evaluateInstance`** (`eval/instance.nix`) — Full single-instance pipeline: normalize → discover deps → resolve → meta checks → config eval → overlays → fixpoint → closure → validation → netpol → scorecard → diagnostics → PackageView → PackageInstance CR.
- **`evaluateImportInstance`** (`eval/import.nix`) — Lightweight path for imports: runs package with null-throwing proxy deps, extracts root's `out`, creates marker PI CR.
- **`mkImport`** — Import marker: `{ from?, out? }`. `from` = optional package function for lazy out derivation.
- **`scope.mkServiceRef` / `scope.mkSecretRef`** (`scope/builders.nix`): a marker for a Service or Secret kix does not render (an operator's `prometheus-operated`, a Secret minted at runtime). `mkServiceRef { name, selector, ports, labels?, requires? }` exposes `out.{name, fqdn, port, labels}` with dependency context; the deploy engine waits for ready endpoints; netpol derives edges from the declared selector; the cross-resource checks and the monitor rule treat the marker as the Service it describes. Since 2026-09 the prometheus, alertmanager and victoria-metrics-cluster packages ref the operator's Services this way instead of rendering their own. A Service kix must render over operator pods declares `kix.dev/operand-of = "<group>/<Kind>/<name>"` instead.
- **`mkScope`** (`eval/scope.nix`) — Per-instance context. Provides: mkResource, mkClusterResource, mkDeployment, mkStatefulSet, mkDaemonSet, forNamespace, mkCRD, mkCRDRef, mkCR, full RBAC DSL. Supports kix and helm label styles via `labelStyle`. mkCRD/mkCRDRef accept per-kind controller declarations that ride into every mkCR-built CR: `factBehavior` (netpol) and `readiness = { path; equals; }` (health convention, stamped as the `kix.dev/readiness` annotation and evaluated by `kix deploy`).
- **`selectorLabelsOverride`** — Override auto-derived selector labels (for immutable selectors on existing workloads).
- **Capability checks** — Lazy checks: `checkCapability`. Guards for loadBalancer, privilegedContainers, daemonSets.
- **`mkNamespace`** (`eval/namespace.nix`) — Creates Namespace resource + optional ResourceQuota + NetworkPolicy resources.
- **`mkPackageView`** (`eval/view.nix`) — Consumer-facing instance shape: folders (plain attrsets), autoKeys (root.out fields), system fields (_type, _packageInstance, root, out, raw, _meta). Known-folder validation (secrets, crds).
- **Helpers** (`eval/helpers.nix`) — `mergeCollide` (collision-detecting merge), `collectTypedAttrs` (recursive `_type` collector), `knownFolders`.

### Composition Helpers (`compose.nix` — the `kix` argument)

- **`port`** — Shorthand: `port "http" 8080` → `{ name, containerPort, protocol }`.
- **`keep`** — Mark a constructor-built container "never collapse to absent": renders `{}` even when every member is null, survives later merges. Backed by collapse-rule normalization (`kix/lib/core/normalize.nix`): literal empties render, all-null containers collapse.
- **`mkEnvVars`** — Attrset → K8s `[{ name, value }]` list. Null values filtered.
- **`mkEnv`** — Combine named env vars with raw K8s env entries (e.g. valueFrom.secretKeyRef).
- **`parseGi`** — Parse K8s resource quantity string (Ti/Gi/Mi) to GiB number.
- **`service.extractPorts`** — Extract service ports from a workload's container spec.
- **`service.fromWorkload`** — Create Service attrset from a workload. Auto-derives selector, ports, outputs.
- **`ingress.fromService`** — Create Ingress attrset from a service. Auto-derives backend name/port.
- **`httpRoute.fromService`** — Create HTTPRoute (Gateway API) attrset from a service. Takes parentRef.
- **`mount.pvc`** — PVC volume mount. Auto-derives name from resource.
- **`mount.configMap`** — ConfigMap mount with optional items, defaultMode, subPath.
- **`mount.secret`** — Secret mount with optional items, defaultMode, subPath.
- **`mount.emptyDir`** — EmptyDir mount with optional medium, sizeLimit.
- **`withMounts`** — Inject mounts into single-container pod spec (pre-seal). Errors on multi-container.
- **`withMountsOn`** — Inject mounts into a specific container by name.
- **`options.ingress`** — Reusable NixOS option set for ingress (host, annotations).
- **`options.monitor`** — Reusable NixOS option set for monitoring (enabled, interval).
- **`expose`** — Build entry: auto-creates Ingress or HTTPRoute based on which DI dep is present (gateway vs ingressNginx). Auto-derives host from cluster.domain. TLS via clusterIssuer. Errors if both gateway and ingressNginx are wired.
- **`monitor`** — Build entry: auto-creates ServiceMonitor + optional PrometheusRule when prometheus DI dep is present. Configurable port, path, scrapeInterval, alert rules (expr, for, severity, description, summary, runbook_url), extraEndpoints, extraLabels.

### RBAC DSL (`rbac.nix`)

- **`group(apiGroup, resources)`** — Named resource refs with `__functor` fallback.
- **`core`** — Pre-populated group for core API ("") with: configmaps, pods, secrets, serviceaccounts, services, endpoints, namespaces, nodes, persistentvolumeclaims, events, etc.
- **Ref modifiers:** `restrictTo(names)`, `sub(suffix)`.
- **Intents (Ref → [Rule]):** `watch`, `reconcile`, `finalize`, `own`, `readWrite`, `full`, `emit`, `watchAndFinalize`, `allow(verbs)`.
- **`grant`** — Flatten and merge rules by apiGroups+verbs+resourceNames.
- **`mkClusterRoleSet`** — Creates ClusterRole + ClusterRoleBinding pairs.
- **`mkRoleSet`** — Creates Role + RoleBinding pairs.

### Helm Bridge (`helm.nix`)

- **`fetchHelmChart`** — Fixed-output derivation: fetch chart from OCI or HTTP registry. Params: repo, name, version, hash.
- **`helmTemplateDerivation`** — IFD derivation: `helm template` → JSON array. Params: chart, releaseName, namespace, values, includeCrds, includeHooks, extraFlags.
- **`wrapHelmResource`** — Wrap single parsed JSON resource into kix resource via scope. Strips Helm annotations/labels, handles foreign namespaces, injects Secret type "Opaque" default, cleans default strategy/updateStrategy.
- **`fromHelmChart`** — Main entry: import Helm chart as kix package. Returns `{ meta, options, build }`. Config-level `values` deep-merged with package-level `values`. Auto-selects root resource (Service > Deployment > StatefulSet > first). Supports `rootSelector`, `patchResources` (pre-wrap transform), filters test hooks, expands List resources.
- **`isClusterScopedKind`** — Check against known cluster-scoped kinds list (14 kinds).

### CRD Builders (`crd.nix`)

Pipeable CRD spec construction:
- **`fromKind`** — Auto-derives plural, singular, listKind. Defaults: Namespaced, v1, permissive schema, status subresource.
- **`clusterScoped`**, **`withVersion`**, **`withShortNames`**, **`withCategories`**, **`withPrinterColumns`**, **`withSchema`**, **`withLabels`**.

### Network Policy Generation (`netpol.nix`)

Internal helpers: `mkServiceRegistry` (service discovery index), `extractServiceEdgesFromJson`, `portsToCilium`, `dnsEgressRule`, `apiServerEgressRule`.

Auto-derives CiliumNetworkPolicy from the DI graph:
- **Auto-detected egress:** API server access (precise — only workloads whose SA is subject of a RoleBinding/ClusterRoleBinding), DNS, cross-package service egress, self-communication (StatefulSet).
- **Auto-detected ingress:** Emitted caller-side at `scope.mkDeployment` time — paired ingress CNP in the callee's namespace via `scope.forNamespace` (v2_discussions/83 Phase C). No cluster-level inverted-ingress pass.
- **Default deny:** Per-namespace, configurable directions (ingress/egress/both).
- Warnings for hostNetwork and Helm opacity (intra-package edges may be missing).

### Fragment Composition (`fragments.nix`)

- **`mergeFragments`** — Merge multiple fragments with collision detection. Instance collision = error. Namespace configs deep-merged (leaf conflicts = error). Platform-owned policies applied on top.
- **`deepMergeNs`** — Recursive namespace config merge.

### Scorecard / Policy Engine (`scorecard.nix`, `rules/`)

- **Rule levels:** manifest, package, namespace, cluster.
- **Severities:** error, warning, info.
- **Override chain:** per-rule > per-owner > per-namespace > rule default > cluster default.
- **`buildScorecardReport`** — Aggregate findings into structured report.
- **`scorecardToWarnings`** — Convert findings to kix diagnostics (errors → assertions, warnings/info → traces).

#### Built-in Rules

**Security:**
- `nonRoot` — Containers must run as non-root (error, CIS).
- `noPrivileged` — No privileged containers (error, CIS).
- `readOnlyRootfs` — Read-only root recommended (warning).
- `noHostNetwork` — No hostNetwork/hostPID/hostIPC (error, CIS).
- `noLatestTag` — No `:latest` or untagged images (warning).
- `hasNetworkPolicy` — Workload namespaces need at least one policy (warning).

**Reliability:**
- `hasResourceLimits` — Every container needs limits (warning).
- `hasResourceRequests` — Every container needs requests (warning).
- `hasProbes` — Liveness + readiness probes (warning).
- `hasPDB` — Multi-replica Deployments need PodDisruptionBudget (warning).
- `gracefulShutdown` — terminationGracePeriodSeconds set (info).

**Governance:**
- `hasOwner` — meta.owner required (warning).
- `hasDescription` — meta.description recommended (info).
- `labelStandards` — Standard K8s labels on workloads (info).

**Architecture** (v2_discussions/128):
- `annotationDomainOwnership` — annotations under an operator-declared domain (`meta.annotationDomains`) require a DI dep on the declarer; undeclared domains warn as dead annotations (warning).
- `unsafeGrants` — audit listing every `meta.unsafe` grant (info).
- `selectorCoherence` — Service selectors must carry store-path context (warning).
- `fqdnWithoutContext` — `*.svc` FQDNs in workloads must carry store-path context (warning).
- `monitorSelectorMatchesService` — ServiceMonitor/VMServiceScrape selectors must match some Service's metadata labels (cluster-level, error). Opt-out for operator-created targets: `kix.dev/monitors-external-service` annotation.
- `externalMonitorTargets` — audit listing every monitors-external-service claim (info).

### Package Metadata & Diagnostics (`meta.nix`)

- **Version system:** `parseVersion`, `compareVersions`, `versionAtLeast`, `versionAtMost`.
- **`peekPackageMeta`** — Extract meta without full evaluation (function, inline, import).
- **`peekPackageAliases`** — Get resolution aliases from available entry.
- **`effectiveAliases`** — Instance aliases override package defaults.
- **`checkMetaStatic`** — Pre-build assertions: K8s version compat, dependency version compat, conflicts, unknown `meta.unsafe` grants.
- **Unsafe grants** (`unsafe.nix`) — closed vocabulary of structural-rule escapes (`raw-pvc`); raw PVCs outside a granted package are an eval error (`scope/validators.nix#checkRawPvc`).
- **Annotation domains** — `meta.annotationDomains` declares operator-owned annotation prefixes; duplicate declarers are an eager eval error (`eval/hooks.nix#buildAnnotationDomainIndex`).
- **Conflict detection:** `conflictsWith` (same namespace) and `cluster:conflictsWith` (cluster-wide).
- **`evaluatePackageDiagnostics`** — Call package-declared warnings/assertions functions.
- **`combineDiagnostics`** / **`collectClusterDiagnostics`** — Merge and enforce diagnostics.

### Environment Stamping (`env.nix`)

- **`mkEnv`** — Stamp instance sets into env-prefixed namespaces (dev/staging/prod). Namespaces become `"${envName}-${setName}"`. Per-instance overrides via `overrides.${setName}.${instName}`. Adds `_envScope` to instances.

### Cluster Module Options (`modules.nix`)

- `clusterLabels` — Labels injected into every resource.
- `clusterDomain` — DNS domain for FQDNs (default: "cluster.local").
- `instances` — Nested attrset: package, aliases, config (deferredModule), deps, partsOverlays, version, labelStyle, selectorLabels, optional.
- `availablePackages` — Package registry for auto-instantiation.
- `autoNamespace` — Default namespace for auto-instantiated packages.
- `namespaces` — Per-namespace: labels, annotations, resourceQuota, networkPolicies.
- `globalPartsOverlays` — Parts overlays applied to ALL instances.
- `global` — Cluster-wide configuration.
- `k8sVersion` — Target K8s version for meta compatibility.
- `cluster.provider` — Distribution identifier.
- `cluster.capabilities` — 8 three-valued substrate axioms: multiNode, availabilityZones, nodeAutoscaling, managedControlPlane, gpu, privilegedContainers, podSecurityEnforcement, daemonSets.
- `cluster.roles` — environment binding modes per registry role (`kix/lib/eval/roles.nix`): absent | shadowable | exclusive.
- `cluster.network` — podCidr, serviceCidr, dnsUpstream.
- `cluster.nodes` — Static node inventory (roles, cpu, memory, labels, taints).
- `scorecard` — enable, rules, ruleDefaults, ruleOverrides, knownAnnotationDomains.
- `networkPolicy` — enable, defaultDeny, directions.

### Cluster Flavors (`flavors/`)

10 distribution profiles, each sets provider, capabilities, and platform imports:

| Flavor | Provider | Key traits |
|---|---|---|
| `k3s` | k3s | loadBalancer (servicelb), flannel CNI, traefik ingress, local-path storage |
| `kind` | kind | Single-node, no loadBalancer, ephemeral storage, kindnet CNI |
| `kubeadm` | kubeadm | Vanilla upstream, minimal defaults, CNI null |
| `eks` | eks | Managed control plane, aws-vpc-cni, EBS CSI (gp3) |
| `gke` | gke | Managed, Cilium-based CNI (k8s-only policies), gce ingress, volume snapshots |
| `gke-autopilot` | gke-autopilot | Fully managed, no privileged containers, no daemonSets, nodeAutoscaling |
| `aks` | aks | Managed, azure-cni, managed-csi storage, volume snapshots |
| `openshift` | openshift | SCC restricted-v2, no privileged, ovn-kubernetes CNI, HAProxy router |
| `rke2` | rke2 | Canal CNI (Flannel + Calico), Calico network policies |
| `talos` | talos | Immutable OS, no SSH/shell, flannel (often replaced with Cilium) |

### Monitoring Module (`modules/monitoring.nix`)

Declarative native Prometheus stack. Options under `monitoring`:
- `enabled`, `namespace` (default: "monitoring-system")
- `operator.enabled`
- `prometheus`: enabled, retention, retentionSize, scrapeInterval, resources, storage, externalUrl
- `alertmanager`: enabled, routing
- `nodeExporter.enabled`, `kubeStateMetrics.enabled`
- `defaultRules`: enabled, per-group rule toggles, per-component monitor toggles
- `grafana`: enabled, rootUrl, persistence, extraDatasources
- `loki.enabled` (Helm-wrapped)
- `promtail.enabled` (Helm-wrapped, defaults to loki.enabled)

### Flake Generation (`mkFlake.nix`)

- Auto-resolves cluster definitions (path → import → callPackage).
- Auto-detects package args (kix, packages).
- Generates: `packages.cluster-${name}`, `packages.cluster-${name}-activation`, `checks` (schema, validation, PI wiring), `legacyPackages` (kixClusters, kixPackages).

---

## CLI — `kix` binary

### Global Flags

| Flag | Description |
|---|---|
| `-o, --output <FORMAT>` | Output format: text, json, yaml |
| `-v, --verbose` | Increase verbosity (stackable: -v, -vv, -vvv) |
| `-q, --quiet` | Suppress non-essential output |
| `--no-color` | Disable colors (also respects `NO_COLOR` env var) |
| `--context <CTX>` | Kubeconfig context |
| `--flake <PATH>` | Flake reference (default: `.`) |

**Env vars:** `KIX_LOG` overrides verbose-derived log filter (RUST_LOG syntax). `KIX_RETRY_ATTEMPTS`, `KIX_REQUEST_TIMEOUT`, `KIX_CONNECT_TIMEOUT` tune the shared apiserver transport policy (retries with backoff, deadlines); `KIX_SWEEP_CONCURRENCY` bounds the managed-resource sweep; `KIX_STALL_TIMEOUT` is the deploy progress watchdog's abort bound (default 600s, `0` never); see HANDBOOK § CLI.

### Commands

#### `kix build <CLUSTER>`
Render all manifests to stdout. Default format: YAML multi-document. JSON outputs array of manifests.

#### `kix diff <CLUSTER>`
Colored diff against live cluster, snapshot, or previous build.
- `--snapshot <PATH>` — Diff against snapshot directory.
- `--from <PATH>` — Build-to-build diff against previous activation result.
- Exit code 2 = differences found, 0 = identical.
- Package-grouped output with resource-level diffs.
- Warns on PVC modifications.

#### `kix check <CLUSTER>`
Three-layer validation: eval correctness → schema compliance (preflight tools like kubeconform) → scorecard policy.
- The eval step is where every build-time check lives: constructor validators, error-level scorecard findings, and the 13 cross-resource resolution checks (`kix/lib/eval/validate.nix`: ServiceAccount, Role, ConfigMap, Service selector, HPA, StatefulSet headless Service, duplicate identity, managed-by label, selector consistency, Ingress backend, Namespace, NetworkPolicy selector, named targetPort). Since 2026-09 those 13 run inside `buildCluster`, so `nix build` and every `kix` command that evaluates a cluster run them; before that they ran only under `nix flake check`. Exemptions and the failure shape are in HANDBOOK §17.4.
- `--sarif` — SARIF 2.1.0 JSON output (GitHub Code Scanning compatible).
- Text output: TOOL | RESULT | DETAILS table.

#### `kix deploy <CLUSTER>` (alias: `kix apply`)
Wave-based deployment with confirmation.
- `-y, --yes` — Skip confirmation.
- `--dry-run` — Preview without applying.
- `--reconcile` — Re-apply all resources (heal drift).
- `--prune` — Delete orphaned resources. Without it the plan still lists every orphan by name and says they are kept. The previous deploy record (Activation) is never an orphan.
- `--prune-mode <MODE>` — default (after apply), eager (interleave), no (skip).
- `--on-error <MODE>` — stop (default) or continue.
- `--timeout <DURATION>` — Readiness timeout (default: 5m).
- `--skip-import-checks` — Skip pre-deploy import verification.
- `--current-activation` — Use local cache instead of fetching from cluster.
- `--operator` — Delegate to kix-operator (creates/patches Activation CR, waits for operator reconcile).

Pipeline: build activation → load store graph → resolve old activation → DAG diff → compute waves → display plan → validate imports → confirm → apply wave-by-wave with readiness checks → prune → record activation.

#### `kix status <CLUSTER>`
Resource health table.
- Default (flat): NAME | NAMESPACE | KIND | READY | STATUS | AGE.
- `--operator` — Package-grouped view with Activation CR metadata, phase-based coloring (Active=green, Deploying=yellow, Failed=red).

#### `kix list clusters`
List all available clusters in the flake.

#### `kix list packages`
List available packages.
- `--cluster <NAME>` — Show per-cluster installation status: installed, installed (auto), import [namespace], available.

#### `kix graph <CLUSTER>`
Dependency DAG visualization.
- `--format <FORMAT>` — tree (ASCII, default), dot (Graphviz), json (nodes/edges).

#### `kix inspect <CLUSTER>`
Cluster structure analysis: total resources, namespaces with counts, resource kinds by frequency, detailed listing.

#### `kix gc <CLUSTER>`
Garbage-collect stale kix-managed resources.
- `-y, --yes` — Skip confirmation.
- **Soft GC** (default) — Diffs old vs new activation store graphs. Fast, no cluster scan.
- **Hard GC** (`--hard`) — Full cluster-wide scan, matches identity-hashes against expected set.
- `--operator` — Deletes retired Activation CRs; operator's finalizer cleans up resources.
- Record retention, in every mode — Superseded Activation records are rollback history, but each one still on the cluster keeps one entry in `kix.dev/activations` on every managed resource, and that annotation is capped at 256 KiB, so they cannot be kept forever. `--keep N` (default 10) always keeps the N newest whatever their age; `--keep-max N` (default 50) never keeps more; `--keep-for 30d` (default) retires anything older beyond the floor (`0` or `off` disables the age rule). Deletes are conditional on the record being unchanged since it was listed. The next deploy drops the retired entries.
- Deletes in reverse dependency order (dependents first).

#### `kix rollback <CLUSTER>`
Rollback to a previous activation.
- `-y, --yes` — Auto-select most recent superseded activation.
- `--dry-run` — Preview only.
- `--prune` — Delete resources only in current activation.
- `--operator` — Patches Activation CR to target's source path.
- Interactive selection: lists superseded activations with metadata, checks store path availability.
- History is bounded by `kix gc` retention (at least the 10 newest, at most 50, and nothing older than 30 days beyond the floor, by default): retired records can no longer be rolled back to.

#### `kix health <CLUSTER>`
Drift detection: compare intended state vs live cluster.
- Walks dependency graph from Activation root.
- Resource states: Healthy, External (import), Missing, AtRisk (depends on unhealthy).
- Package states: healthy, external, DEGRADED, AT RISK.
- Exit code 1 if issues found.

#### `kix snapshot save <DIR>`
Save live cluster state to directory. Discovers all API resources, fetches all kix-managed resources, writes by namespace. Path traversal protection.

#### `kix snapshot diff <CLUSTER> <DIR>`
Diff snapshot against rendered manifests. Detects renames/moves via fuzzy similarity matching. Exit code 2 = differences.

#### `kix completions <SHELL>`
Generate shell completions (bash, zsh, fish).

### Manifest Stamping (Annotations & Labels)

All kix-managed resources receive:
- `kix.dev/identity-hash` — Blake3 content hash (change detection).
- `kix.dev/depends-on` — Comma-separated dependency identity-hashes.
- `kix.dev/package` — Package instance name.
- `kix.dev/package-namespace` — Package namespace.
- `kix.dev/mode` — "import" for external resources.
- `app.kubernetes.io/managed-by: kix` label.
- `kix.dev/cluster` label.

Activation CR extras: `kix.dev/built-via` (store path).

---

## kix-operator

Long-lived K8s controller watching Activation CRs.

- **Activation lifecycle:** Queued → Deploying → Active → Superseded.
- **Reconcile loop prevention:** Stream-level generation filter (ignores status-only updates).
- **Requirements:** `nix-store` binary on host, read access to `/nix/store/`.
- **Finalizer-based cleanup:** Resources cleaned when superseded Activation CRs are deleted.

---

## Library Internals (kix Rust crate)

### eval module
- `KixEvaluator` — Main entry point. `NixBackend` trait for pluggable backends.
- `ClusterOutput` — Evaluation result (manifests, store graph, scorecard).
- `StoreGraph` — Package/resource DAG from Nix store.
- SQLite-based eval caching.
- Mock backend for testing.
- `ffi` feature flag for direct Nix FFI backend.

### manifest module
- **Structural diff engine:** path-based differences, keyed-list array diffing, rename/move detection (fuzzy similarity), configurable ignore rules, field labels.
- **Serialization:** YAML/JSON I/O, `load_manifests_from_dir`, `write_manifests_to_dir`.
- **Validation:** `run_preflight` for schema/validation tools.
- **Stamping:** Annotation injection (identity-hash, depends-on, package metadata).

### cluster module
- **Activation:** find_active, list_superseded_activations, retire_plan (`gc --keep`), Activation CR lifecycle management.
- **Apply:** `detect_changes` → ChangeAction (Apply, Skip, Orphan). ApplyAction (Created, Configured, Unchanged, Skipped).
- **Fetch:** API resource discovery, fetch all kix-managed resources, normalize for diff (strip server-side fields).
- **Graph:** ResourceGraph with tree/dot/json output.
- **Imports:** collect import markers, validate against live cluster.
- **Readiness:** Per-kind checks (Deployment, StatefulSet, Job, DaemonSet, etc.), configurable timeout.
- **Reconcile engine:** Wave-based apply with `ReconcileObserver` trait for progress callbacks. `ReconcileEvent` types: WaveStart, ResourceApplied, ReadinessWaiting, etc. OnErrorPolicy (Stop, Continue), PrunePolicy (Skip, WarnOnly, Delete).
- **Waves:** Topological sort into parallel-safe deployment waves.

---

## Exit Codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Error / validation failure / failed resources |
| 2 | Differences detected (diff, snapshot diff) |
