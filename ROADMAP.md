# Roadmap

## Foundation (core engine)

- [x] no "defaults"
- [x] Module system via NixOS evalModules for cluster composition
- [x] Global scope object with per-instance context (mkResource, mkClusterResource, rbac helpers)
- [x] Fragment system for separating concerns and teams (mergeFragments with collision detection)
- [x] Content-addressed resources — mkResource produces rich objects with `.out` (name, selector, fqdn, etc.)
- [x] Dependency tracking via Nix string context (attachCtxDeep)
- [x] Helm integration (fetchHelmChart, fromHelmChart, wrapHelmResource)
- [x] Content-hash and identity-hash annotations on resources
- [x] depends-on annotation derived from context
- [x] @luca Post-eval validation — catch errors at build time, not deploy time
  - Cross-namespace scope validation (`meta.scope = "namespace"` prevents cross-ns DI)
  - Consumer-side dependency validation (immich validates postgres has pgvecto.rs extension via `postgres.out.extensionNames`, warns on undersized PVCs)
  - Redundant/duplicate requires detection, orphaned resource detection
  - [ ] General validation framework — package-declared requirements on dependencies (beyond ad-hoc checks). `meta.nix` already has `checkMetaStatic` (k8s version bounds, `compatibleWith`, `conflictsWith`, deprecated) and `evaluatePackageDiagnostics` (custom assertion functions). What's missing: declarative dep constraints (e.g. `deps.postgres.requires.extensions = ["pgvecto.rs"]`) so packages don't write imperative check functions for common patterns. Ties into the structured deps design — if deps become a returned attrset, validation constraints can live right on the dep declaration.
- [ ] @luca Auto-inject dependencies (e.g. valkey for immich) — the "just make it run" experience where pulling in an app auto-enables what it needs
  - [x] **DI resolution**: explicit override → same-namespace match → cluster-wide match → Nix default → error. Aliases supported. This resolves against *existing* instances in the cluster.
  - [x] **DI-driven defaults** (immich): ingressNginx injected → auto-create ingress (no `enabled` flag); clusterIssuer injected → auto-enable TLS. className derived from `ingressNginx.out.ingressClassName`. TLS secret name auto-derived. Now implemented as `kix.expose` composable build entry — app developers add `(kix.expose { service = "service"; })` to their build list and never touch infrastructure deps directly. `kix.expose` is now dual-mode: detects `gateway ? null` (Gateway API → emits HTTPRoute) vs `ingressNginx ? null` (legacy → emits Ingress). Clusters choose their approach by which controller package they instantiate. See `v2_discussions/62a_exposure_as_composable_build_entry.md`, `v2_discussions/70_gateway_api_migration.md`.
  - [x] **DI-driven defaults** (remaining): applied to n8n, metabase, harbor, python-app (shopfront/ledgerly), velero. Prometheus DI gates ServiceMonitor creation in immich, harbor, coredns. `cluster.domain` provides default host (`"${instanceName}.${cluster.domain}"`). S3 object storage as `mkImport` with explicit `out` (hetzner-s3, ovh-s3 in nw1). Velero exposes `out.withBackup`/`out.withoutBackup` transformers. StackGres takes `storageClasses ? null` for storage DI. See `v2_discussions/39_di_driven_defaults_design.md`.
  - [x] **Auto-instantiation from default package set**: `availablePackages` in `modules.nix` is the cluster-level registry; `computeAutoInstances` in `eval/auto.nix` uses `builtins.genericClosure` for transitive reachability — when a hard dep has no matching instance, it is auto-created from the registry. Also activates `optional` instances when depended on. Resolution order: (1) match concrete instance in cluster, (2) fall back to alias, (3) auto-instantiate from default package set.
  - (pot nonsense:) Two-tier model: auto-enable if a dependency exists in the cluster; explicit enable triggers full transitive pull-in of everything needed
  - [x] Packages can declare **default aliases** alongside their options and builders (e.g. cert-manager aliases `clusterissuer`), so dependencies can resolve against general capabilities, not just package names — `meta.defaultAliases` on the package; `effectiveAliases` / `peekPackageAliases` in `meta.nix` merge package-declared and instance-level aliases
  - [x] The available package list for auto-resolution must live under a **dedicated config path** — `availablePackages` option in `modules.nix`; accepts raw package functions or `{ package, namespace?, aliases? }` attrsets
- [x] v2_discussions/11 → injecting storage, certs, and other infra items from the cluster graph (different package types?)
  - Storage DI: PVCs are first-class instances in the cluster definition (packages/persistent-volume-claim). storage-classes exposes `out.storageClassName`. Consuming packages (e.g. immich) take `storage` as a hard DI dep, mount via `storage.out.name`. Package `meta` (lifecycle, scope) enables cross-namespace validation and kix-diff protection.
- [x] Use "already existing" cluster elements — `kix.mkImport { from = package; }` evaluates packages in import mode (lightweight `mkImportResource`, no store paths) to derive `out` properties for DI resolution. Deployed as a marker PackageInstance CR only.
  - [x] kix deploy should verify imported resources actually exist in the live cluster — import markers now carry `kix.dev/import-kind` and `kix.dev/import-apiversion` (auto-derived from `from`-based imports, optional for raw imports). CLI collects import markers, performs targeted GET requests before wave deployment, and fails fast if resources are missing. `--skip-import-checks` flag to override. See also: flavor-provided DI imports below.
  - [x] Flavor-provided DI imports for system services — all 10 flavors now provide `mkImport` instances for platform-managed services. `buildCluster` injects `mkImport` into specialArgs so flavors can create imports without callers passing the full kix library. DNS imports (`platform-dns` with alias `dns`) in all flavors. Storage imports (`platform-storage` with alias `storageClasses`) in flavors with built-in storage: GKE (`standard-rwo`), GKE Autopilot (`premium-rwo`), EKS (`gp3`), AKS (`managed-csi`), k3s (`local-path`), kind (`standard`). All flavor imports are `optional = true` — they activate only when depended on. DI resolution prefers managed instances over imports, so a cluster-installed `storage-classes` package automatically shadows the flavor's import without ambiguity errors. See `lib/flavors/*.nix`, `lib/eval/resolve.nix` (import-aware resolution), `lib/eval/cluster.nix` (mkImport in specialArgs, isImport in staticMeta).
- [ ] Default metadata scoping — which resources should global metadata apply to? Not higher-order resources like Deployments/Services, but what about CRDs?
- [ ] Non-manifest side effects — external imperative actions (e.g. creating a Forgejo user, provisioning a DNS record) as first-class graph nodes alongside manifests. kix deploy resolves these as tasks, not resources. Later feature — requires extending the graph model beyond K8s manifests
- [ ] "Wire" vs "compose" coherence — sharing selectors by reference can copy wrong state if labels are accessed; post-processing breaks composition. Needs a principled solution
- [ ] Higher-level abstractions must "imprint" on resources — all relevant information from higher-level logic should be visible on the underlying K8s resource for auditability and tooling
- [ ] Dynamic duplicate dependencies — the same resource (e.g. a second CoreDNS) can be pulled in twice; deduplication is the consumer's responsibility, not the creator's
- [ ] mkManifest pre-creation hook as escape hatch — global function hook for raw access to any resource before it becomes a manifest
- [x] CRDs, creation and basic usage — `mkCRDRef` creates CRD references with auto-generated `mkCR` builders; used by cert-manager, stackgres, monitoring packages
  - [ ] (low priority) CRD schema management, verification against live cluster, and import from existing CRD definitions — requires either a Nix-native OpenAPI subset validator or the Rust oracle at fixpoint (doc 36). Deferred until the Rust integration path is clearer.
- [ ] auto-sealing of resources? => evaluator turns every attrset that has a "kind" attribute into a resource on first pass of the fixpoint
- [ ] aliases and meta could be on the packages options maybe? => allows default aliases to just be a mkDefault
- [ ] smarter store paths. Nixos puts the package version into the storepath hash-name-version. This helps a lot with diffing fast.
- [x] package definition from dependencies as top level closure input to an explicit dependencies attrset that can carry more information and value (only depend if config.X is set etc). Then pass deps to build closure. This likely makes the fixpoint simpler as well.
  - Implemented in `lib/eval/resolve.nix`: `normalizePackage`/`callPackagePhase1` calls package with only system args → returns `{ meta, options, deps?, build }`. `discoverBuildDeps` introspects build function args; `resolveDeclaredDeps` resolves against the cluster. `lib/eval/instance.nix` wires the full two-phase pattern. Packages (e.g. immich) return `{ meta, options, deps, build }` with deps as build function arguments.

### Validation

- [ ] Deep-check package-level dependencies — verify the package root CRD is pulled in properly
- [ ] Rethink package CR (PackageInstance) wiring and store path visibility — currently `mkCRDRef` creates standalone `crd-ref-*` store paths with no back-reference to the providing package's PackageInstance. Cross-package CRD dependencies don't show up in the Nix store DAG. Need to decide: should the providing package's store path be threaded through the CRD ref context, or should cross-package deps be tracked at a different level?

### Open design questions
- [ ] Package root as common leaf dependency or root
- [ ] Direction of abstraction: deploying an app ON a surface (cloud-run-like) vs. wrapping/composing an app IN a surface (being cloud-run) — this is a concrete UX question that shapes the entire API
- [ ] How to model the derivation vs resource vs module tension — three competing goals in direct conflict: (1) perfectly verifiable traceability (security), (2) complete customization (maintenance), (3) ease of consumption. Modules can't support duplication (multiple SAs), derivations can't be post-modified, resources easily lose dependency tracking
- [ ] Content-addressing means updates launch side-by-side (different hash), not in-place replacement — native K8s rolling update semantics become incompatible. This is a fundamental design property that needs explicit handling
- [ ] Kubenix-style service definitions (`services.coredns."default".enable = true`) — allows multi-instance, attribute-set-keyed service declarations
- [ ] Move to manifest module system — explicit migration step for how manifests are composed
- [ ] a "kix managed only" mode
- [ ] multi-activation support => should they be mutually exclusive? (prepending all names with the cluster name) or should they share resources => same hash, same resource? (makes things like postgres probably tough (?))

## Security & compliance

> "Security teams have money — platform teams do not. But platform teams can get money from security."

- [x] Package ownership model — `meta.owner` field on packages, surfaced in `kix list packages` (text and JSON). OWNER column auto-hides when no packages declare owners. Foundation for IDP catalog, scorecards, and team-scoped views.
- [ ] Security defaults via mkDefault — e.g. all pods non-root by default, users must mkForce to override
  - mkForce as an auditable signal: any use of mkForce to override security defaults can be flagged, surfaced in review, or blocked by policy
  - The full nix module priority hierarchy (mkDefault → normal → mkOverride → mkForce) is what makes multi-team cluster configs maintainable at scale
- [ ] CVE tracking — integrate with NixOS security tracker (https://tracker.security.nixos.org/suggestions/) for awareness of vulnerabilities in dependencies
- [x] Scorecard rules — multi-level policy evaluation framework (manifest, package, namespace, cluster). Built-in rule library (`lib/rules/`) with 15 rules covering security, reliability, and governance. Configurable severity per scope (namespace, owner, rule). Findings feed into kix diagnostics: error-level block the build, warnings are traced. Cluster config via `scorecard` module option. See `lib/scorecard.nix`, `lib/rules/`, `clusters/nw1/scorecard.nix`.
- [ ] Compliance exports — CycloneDX SBOM, SLSA provenance, OSCAL assessment results (see `v2_discussions/61_compliance_exports.md`)
  - [x] SARIF export — `kix check <cluster> --sarif` outputs SARIF 2.1.0 JSON from scorecard findings. Nix-side scorecard report serialized to `kix-scorecard.json` in the activation result dir, read by CLI backend. GitHub Code Scanning integration via `github/codeql-action/upload-sarif`. See `v2_discussions/64_mvp_implementation_approach.md`.
- [ ] Automated compliance — continuous verification against regulatory frameworks (SOC2, HIPAA, PCI-DSS)
- [ ] Secret handling and injection (agenix, etc.) — hashes of encrypted secrets don't trigger spurious changes; injection happens in kix-deploy
  - [x] **Secret primitives**: `scope.mkSecret` (kix-managed, inline stringData or SOPS source+hash) and `scope.mkSecretRef` (externally-managed, no manifest). Both expose enriched `out` API: `keyRef`, `mkEnv`, `envFrom`, `volume` with build-time key validation. `kix.dev/secret-keys` annotation stamps declared keys. Standalone `packages/secret` and `packages/secret-ref` for cluster-level instances via DI. See `v2_discussions/76_secrets_design.md`.
  - [x] **Package migration**: grafana, alertmanager, firezone, harbor, external-dns, velero, valkey, python-app, n8n, metabase migrated from raw `scope.mkResource { kind = "Secret"; }` to `scope.mkSecret`/`scope.mkSecretRef`. String-only secret references (`secretRef.name = someString`) replaced with `out.envFrom`/`out.keyRef` for dependency tracking.
  - [x] **SOPS deploy-time hydration**: `kix deploy` detects Secrets with `kix.dev/sops-source` annotations, decrypts via `sops --decrypt`, optionally verifies `kix.dev/content-hash`, injects plaintext into `stringData` before applying. Integration-tested with kind cluster + age-encrypted SOPS file. See `cli/kix/src/cluster/secrets.rs`, `clusters/test-secrets.nix`, `tests/secrets-integration.sh`.
  - [ ] SOPS CLI commands — `kix secrets generate/rotate/update-hash` for managing SOPS files and hashes
  - [ ] Auto-management — weekly rolling of auto-created credentials (e.g. postgres users)
  - [ ] Revoking team member permissions
- [ ] Supply chain security (SLSA) — locked inputs for everything: not just flake inputs but arbitrary external git refs, downloads (must carry hash), and file references. Partial immunity to supply chain attacks
- [ ] Run static analysis of kyverno and other policy engines at build time — sane defaults out of the box
- [x] Network policies — autogenerate, check, verify, and abstract (cilium compatible); can be partially inferred from dependency graph (if you depend on a service, you need DNS access to it)
  - Implemented in `lib/netpol.nix` (430+ lines): auto-derives CiliumNetworkPolicy from the store-path dependency graph. Module option `networkPolicy` in `lib/modules.nix` with `enable`, `defaultDeny`, and `directions` flags. Auto-detects API server access, external ingress, self-communication; generates per-workload egress and per-service ingress rules.
  - [ ] Network policies should be attached per-resource, not per-instance. Currently policies are collected on `_networkPolicies` at the instance level and injected in `cluster.nix`. They should instead be associated with the individual resources (workloads/services) that generate them, so they participate naturally in the store DAG and resource-level dependency tracking. See `v2_discussions/37_di_derived_network_policies.md` for the design: derive NetworkPolicies directly from DI graph + store-path DAG edges, per-workload egress and per-service ingress, without a separate connection graph abstraction.
  - [ ] Network policy generation is hard-coded to CiliumNetworkPolicy. Should respect `cluster.capabilities.networkPolicyAPI`: generate standard K8s NetworkPolicy when `"k8s"`, CiliumNetworkPolicy when `"cilium"`, CalicoNetworkPolicy when `"calico"`, and skip generation entirely when `"none"`. Currently any cluster with `networkPolicy.enable = true` must have Cilium.
- [ ] Permission system in kix deploy — what blast radius am I allowed to have

## System contracts and cluster capabilities

> See `v2_discussions/48_system_contracts.md` for full design decisions.

- [x] Cluster hardware profile — `cluster.provider`, `cluster.capabilities.*`, `cluster.network.*`, `cluster.nodes` module options. Flavor presets in `lib/flavors/` for 10 distributions. See `v2_discussions/45_cluster_hardware_profile.md`, `lib/modules.nix` (capability option definitions with TODO annotations), `lib/flavors/*.nix`.
- [x] Capability checks at resource construction — `lib/eval/scope.nix` checks `loadBalancer` (on Service type=LoadBalancer), `daemonSets` (on DaemonSet), `privilegedContainers` (on hostNetwork/hostPID/privileged). Capabilities flow from `clusterConfig` → `lib/eval/instance.nix` → `mkScope`.
- [ ] Auto-injected DNS dependency — post-evaluation pass (like `lib/netpol.nix`) that detects FQDN references in resources and auto-adds a store-path edge to the `dns` DI provider. Ensures correct deploy ordering and build-time error if no DNS provider exists. Packages with `meta.defaultAliases = ["dns"]` (e.g. coredns) satisfy this automatically.
- [ ] Post-eval verification for Helm imports — scan resources from `fromHelmChart` for implied prerequisites (PVCs without `storageClasses` provider, Ingress without `ingressController`, LoadBalancer without capability). Safety net for opaque resource sets that bypass DSL-level DI wiring.
- [ ] Migrate capability TODOs to DI — several capabilities are marked for DI migration in `lib/modules.nix`: `ingressController` → DI dep with `out.ingressClassName`; `cni` / `networkPolicyAPI` → CNI as DI dep with `out.networkPolicyAPI`; `rwxStorage` → storage provider `out.accessModes`; `volumeSnapshots` → snapshot controller DI dep.
  - [x] **Gateway API support**: `packages/envoy-gateway/` provides GatewayClass + Gateway with `out.gatewayRef` DI contract. `kix.expose` auto-detects gateway vs ingress-nginx and emits HTTPRoute or Ingress accordingly. `httpRoute.fromService` builder in `lib/compose.nix`. ludo cluster uses Gateway API; nw1 remains on ingress-nginx. Zero app-package changes needed — `kix.expose { service = "service"; }` works with either controller. See `v2_discussions/70_gateway_api_migration.md`.

## Platform capabilities (module-level features)

> "If Prometheus is already there, why not auto-enable it in CoreDNS?"

- [x] Monitoring module — native Prometheus stack packages replace monolithic kube-prometheus-stack Helm chart. See `v2_discussions/68_prometheus_stack_kix_native.md`.
  - [x] `kix.monitor` composable build entry — like `kix.expose` but for monitoring. Packages add `(kix.monitor { service = "service"; port = "metrics"; })` to their build list and get ServiceMonitor + default PrometheusRules auto-generated when prometheus is available via DI. Parameters: `service`, `port` (default "metrics"), `path` (default "/metrics"), `alerts` (attrset of alert definitions), `extraEndpoints`, `extraLabels`. Standardized options via `kix.options.monitor` (`enabled`, `interval`). Implemented in `lib/compose.nix`.
  - [x] `packages/prometheus-operator/` — CRDs + operator Deployment + RBAC. Exposes `out.mkServiceMonitor`, `out.mkPodMonitor`, `out.mkPrometheusRule`, `out.mkPrometheus`, `out.mkAlertmanager`, `out.mkProbe`. Eliminates the `partsOverlays` CRDRef hack.
  - [x] `packages/prometheus/` — Prometheus CR (operator manages StatefulSet). Configurable retention, storage, scrape intervals. Exposes `out.serviceUrl`.
  - [x] `packages/alertmanager/` — Alertmanager CR. Cluster-level routing config via options.
  - [x] `packages/node-exporter/` — DaemonSet + ServiceMonitor + PrometheusRules via `prometheus ? null` DI.
  - [x] `packages/kube-state-metrics/` — Deployment + ClusterRole + ServiceMonitor via `prometheus ? null` DI.
  - [x] `clusters/ludo/monitoring.nix` — migrated to native packages (including native Grafana).
  - [x] Monitoring module — `kix.modules.monitoring` in `lib/modules/monitoring.nix`. `monitoring.enabled = true` instantiates the full stack. Per-component options: `monitoring.prometheus.retention`, `monitoring.grafana.enabled`, `monitoring.loki.enabled`, etc. Auto-wires Grafana datasources via DI, Prometheus→Alertmanager connection.
  - [x] `packages/grafana/` — Native Grafana package with k8s-sidecar dashboard/datasource provisioning, DI-wired datasources, optional ServiceMonitor, ClusterRole RBAC for sidecars.
  - [ ] Migrate nw1 to native monitoring stack.
- [ ] Capability switchboard — turning on Prometheus sets `config.metrics.enabled` globally; packages can react with `lib.mkIf config.services.prometheus.enable`. This is also a platform capability signal: a machine-readable, introspectable feature advertisement (could also exist for AI)
- [ ] Modules that auto-configure based on cluster features — "if we have a prometheus, I will use it"; "wherever I run, I expect a DNS entry for X"
- [ ] Importable decision sets — like nixos-hardware profiles but for clusters (e.g. `import security-hardened` changes default pod settings across all packages)
- [ ] Community module registry — e.g. a CNCF k8s-packages flake where `services.rook.enable = true` just works
- [ ] Separation of team concerns with priority — security team can push requirements at higher priority on every module, not just as pre/post processors but as orthogonal constraints

## Warnings, errors, checks

- [x] Misuse of `requires` detection
- [x] Missing resources in graph detection
- [x] Build-time error on illegal configurations — immich throws at eval time if postgres is missing required pgvecto.rs extension (`postgres.out.extensionNames`). Infra packages expose validated metadata via `main.out` for consumer-side checks.
- [x] Compatibility checks on packages — `meta.nix` checks k8s version bounds (`meta.k8s.minVersion/maxVersion`), dep version ranges (`meta.compatibleWith`), conflict detection (`meta.conflictsWith`), and deprecation warnings (`meta.deprecated`)
- [ ] Sanity checks on namespace resource quotas and similar
- [x] Stateful resource discovery — package `meta.lifecycle = "stateful"` flags stateful packages; `meta.scope = "namespace"` prevents cross-namespace DI for namespace-bound resources (PVCs). Consumer-side validation (e.g. immich warns if PVC < 50Gi) via `builtins.trace` in build.
- [ ] Compatibility matrix — four distinct failure phases: build, deploy, health, application. Need to know *when* things will fail, not just *if*
- [ ] Encodable "known issues" — broken side effects should be expressible in code so a problem can't recur; capturing institutional knowledge about failure modes directly in the DSL
- [ ] Templating parity — ensure the DSL can express everything a Helm template can, as a migration enabler
- [ ] Helm compatibility mode for live cluster migration — a flag (per-instance or global) that makes kix produce Helm-style labels and annotations (`app.kubernetes.io/managed-by: Helm`, `meta.helm.sh/release-name`, `meta.helm.sh/release-namespace`) so that `kubectl apply` adopts existing Helm-managed resources without conflicts. Enables zero-downtime migration from Helm to kix on live clusters. `labelStyle = "helm"` partially exists but doesn't cover Helm's ownership annotations.
  - [ ] `fromHelmChart` should preserve Helm's kind-based resource ordering (Namespace → SA → ConfigMap → RBAC → Deployment → Service → Ingress) when loading resources, so the kix deploy wave order matches what Helm would do — avoids surprises during migration where resources appear in a different apply sequence
- [ ] allow a resource to be defined as `self.deployment = moved { new attr name, message }` to inform a consumer of changes. We could have more and more advanced of these.

## DSL improvements

- [x] Auto-derived selectors on resources (.out.selector)
- [x] RBAC DSL — pipe-friendly intent-based API (watch, reconcile, own, grant, etc.)
- [x] Auto-selectors derived from resource spec/labels (`.out.selector`)
- [x] RBAC DSL with intent-based verbs
- [ ] HPA as dependency / composition — auto-wires scaling to the right target
- [x] Pipe-friendly resource composition — `binary |> as deployment |> expose { port = 9090; }` — kix as *the* platform engineering language, replacing the wild west of ansible/helm/scripts
  - Implemented in `lib/compose.nix`: extensive `|>` pipe operator usage for service composition (`deployment |> kix.service.fromWorkload |> scope.mkResource`), mount injection, and resource building
- [x] Composable build entries for cross-cutting concerns — `kix.expose` extracts ingress/TLS wiring into a reusable build entry that declares its own DI deps (`ingressNginx ? null`, `clusterIssuer ? null`). App developers add it to their build list without touching infrastructure deps. `discoverBuildDeps` unions deps from all entries with correct optionality (required wins over optional). `kix.options.ingress` provides standardized `{ host, annotations }` options. Migrated: immich, n8n, metabase, vaultwarden, filebrowser, firezone. Harbor and python-app kept manual (complex multi-path routing). Pattern generalizes to `kix.monitor`, `kix.backup`.
- [ ] Builder/transformer placement — should package builders (`withCert`, `mkCertificate`) live on `out` (via `main.out`) or on parts directly? Current: `main.out` for DI-visible transforms, parts for package-internal helpers like `mkCertificate`. Storage uses plain values (`out.storageClassName`) rather than transformers. Needs a clear convention as more infra packages expose builders
- [ ] Remove `outputs` design — custom `outputs` on `mkResource` is a bolted-on escape hatch; port, fqdn, and other DI-visible values should be auto-derived or come from a richer `out` model, not manual string declarations per resource. `main.out` (package-level out) partially addresses this — it allows complex types (lists, functions) beyond stringified resource outputs (e.g. stackgres-cluster exposes `out.extensionNames` as a list, cluster-issuers exposes `out.withCert` as a function). But per-resource `outputs` still exists for simple string values like port.
- [ ] Port wiring logic — carry port information up through container → pod → service → ingress; prevent wiring things that don't have a route
- [ ] Functional composition as correctness — "this service wraps this app, this HPA wraps this app, you figure out the rest"; correct wiring emerges from composition, not from template deduplication
- [ ] Image convention — `"${config.image.repository}:${config.image.tag}"` + `imagePullPolicy` is repeated in every package. Standardize as a single option (full image string or structured with a helper) so packages don't each reinvent image construction
- [x] Better CoreDNS corefile handling
  - `packages/coredns/helpers.nix`: structured Corefile generation with `renderPlugin()`, `renderServerBlock()`, `renderSnippet()`, `mkCorefile()`, and `defaultServer` definitions. Structured server definitions via package options.
- [ ] Full CoreDNS binary building
- [ ] selector based on "identity" to say "i want this and exactly this resource"
- [x] Post-hooks on root — `root = { resource = ...; postHooks = [ self.migrationJob ]; }`. Post-hook resources are deployed AFTER all other package resources (they must depend on forward-closure resources for wave ordering). PackageInstance CR depends on them via `kix.dev/post-hooks` annotation, so the package isn't "done" until post-hooks complete. Jobs use existing readiness logic (`status.succeeded >= 1`). Warnings emitted if a post-hook doesn't reference any forward-closure resource. Enables Helm hook migration (pre-install/post-install Jobs).

## Post eval validation (kix validate)

- [ ] (low priority) OpenAPI schema validation at build time — K8s resources have a known openAPI spec, verify against it during eval. Blocked on CRD schema validation infrastructure; deferred.


## Drift detection & diffing (kix diff)

- [x] kix-dump — normalize and dump live cluster state
- [x] kix-diff — compare kix output against dump (summary, renames, modified, identical)
- [x] Diff on instance level (grouped by package instance)
  - `cli/kix-cli/src/plan.rs`: `diff_graphs()` groups by `(namespace, instance_name)`. Python version in `tools/kix-diff/kix-diff.py`: `diff_packages()` returns grouped diffs by package key.
- [x] Diff on resource level (individual resource changes)
  - `cli/kix-cli/src/plan.rs`: `diff_package_resources()` produces per-resource diffs via `PackageChangeDiff.resource_diffs`. Python version in `tools/kix-diff/kix-diff.py`: `diff_manifests()` with per-resource output.
- [x] Structured diff output for CI/automation — `kix diff --output {json,yaml,markdown}`. Markdown emits a GitHub PR-comment format (summary line, added/removed/changed package lists, collapsed `<details>` per changed package with added/modified/removed/dep-affected resources). JSON and markdown are produced by shared `plan::render_package_diff_json()` / `render_package_diff_markdown()` so the deploy modal, `kix diff`, and the (future) PR-comment GitHub Action all consume the same PackageDiff producer. `v2_discussions/84_m0_m1_implementation_plan.md` §5.
- [x] Distinguish real content changes from dependency-propagated changes — `cli/kix-cli/src/plan.rs` `diff_package_resources()` now partitions each resource's structural diffs via `partition_propagation()` / `is_propagation_path()`: diffs whose path is exactly `$.metadata.annotations.kix.dev/{identity-hash,depends-on,activations,built-via}` are propagation-only. Resources with only propagation diffs land in a new `dep_affected_resources` field on `PackageChangeDiff` (separate from `resource_diffs`). `print_package_plan`, `print_plan_summary`, and `diff` text/JSON output surface them under an "affected via dependency" section and a `Resources: N real content, M dep-affected` summary line, so hash-propagation bumps no longer drown real field changes.
- [ ] Warnings when PVCs change or major versions change — hint on the package definition
- [ ] Live-cluster sanity checks (resource limits, etc.)
- [x] Content-hash-based drift detection — recompute hash and compare against live state, contrast with nix store evaluation
  - `kix health` builds intended state, normalizes both sides, compares Blake3 content hashes. Reports InSync/Drifted/Missing per resource.
- [x] Health check: package-level grouping — resources grouped by `kix.dev/package` annotation, per-package status (healthy/degraded/at-risk)
- [x] Health check: blast radius analysis — walks dependency graph forward from broken resources to find at-risk dependents. Shows dependency chains in verbose mode.
  - `cli/kix-cli/src/commands/health.rs`: `compute_blast_radius()` does BFS through `ResourceGraph::dependents()`, marks transitive dependents as AT RISK with reason chains
- [x] Health check: active activation scoping — BFS from the active activation's identity hash filters out superseded activations and their orphaned dependencies, so health only reports on the live deployment graph.
- [ ] Merkle-walk integrity check — fast health check without nix build. Walk from the Active Activation CR through `kix.dev/depends-on` edges, verifying identity hashes at each node. Requires enriching `kix.dev/depends-on` with resource hints (`hash:kind/namespace/name`) for targeted GETs instead of full LIST. Two modes: fast integrity (graph walk only) and deep drift (content-hash comparison). See `v2_discussions/archive/51_merkle_health_check.md` for full design.
- [x] Content-hash normalization for change detection — the live resource always contains server-added fields (uid, resourceVersion, creationTimestamp, defaulted values, status). The content hash must be computed on a normalized representation that strips these fields before comparison, otherwise re-deploy always sees "changed".
  - `cli/kix/src/cluster/normalize.rs`: `normalize_for_content_hash()` strips server metadata, status, kix annotations, kubectl bookkeeping, null values, and sorts keys. `cli/kix/src/cluster/fetch.rs`: `normalize_for_diff()` removes uid, resourceVersion, creationTimestamp, generation, managedFields, status, and last-applied-configuration. Python parity version in `scripts/parity/normalize.py`.

## Deployment & reconciliation (kix deploy)

- [ ] Deploy target verification — stamp `cluster.provider` and allowed kubeconfig contexts into the Activation CR (`kix.dev/provider`, `kix.dev/allowed-contexts`). `kix deploy` checks the target `--context` against `cluster.deploy.allowedContexts` before applying, preventing accidental cross-environment deploys (e.g. deploying a kind-targeted build to production). Simple string match on context name — no fragile auto-detection.
- [x] Wave rollouts — dependency graph fully describes deployment order; deploy in correct waves with CRD re-discovery between waves
- [x] Wait for ready across all resource types (Deployment, StatefulSet, DaemonSet, Job, PVC, CRD, generic CR conditions)
- [x] Activation CR deployed as cluster-level deployment record; stale Activations cleaned up post-deploy
  - [x] Activation name includes identity-hash prefix (e.g. `kind-52943986w98c`) so each deploy creates a distinct CR, enabling supersede/rollback lifecycle. Stamped in `stamp.rs`.
  - [x] `kix.dev/built-via` annotation on Activation CRs stores the result dir store path, so rollback and deploy can load manifests without a nix rebuild. Used by `rollback.rs` and `deploy.rs` `load_old_from_cluster`.
  - [x] `finalize_deploy` uses merge patch (not SSA) to supersede old activations, preserving `kix.dev/identity-hash` and other annotations.
  - [ ] Activation CR should be deployed first (wave -1) with `status.phase: Deploying`, then finalized to `Active` at the end. Currently deployed in the last wave, so `begin_deploy` progress recording 404s on first deploy (harmless, logged at debug level). Deploying first also enables crash recovery — the Activation exists on the cluster before any resources are applied.
  - [ ] Old Activation prune policy — superseded Activations are currently warn-only during prune ("prune policy is warn-only"). They must be kept for rollback, but the message is confusing. Should either explicitly skip Activations during prune with a clear message, or have a separate `kix gc --activations` to clean old ones.
- [x] `kix gc` — garbage-collect orphaned kix-managed resources against a cluster's expected manifest set
- [ ] `kix gc` without cluster eval — GC purely from live Activation/PI graph (no nix eval required)
- [x] `kix gc` shows exactly which resources will be deleted before collection. Soft GC (`print_package_plan` with forced-verbose) lists every removed resource per package. Hard GC (`print_garbage_plan` in `cli/kix-cli/src/commands/gc.rs`) groups garbage by namespace+kind and annotates each entry with identity-hash, orphaning reason (`identity-hash not in expected set` / `missing kix.dev/identity-hash` / `superseded activation`), owning package, and activation hashes pulled from `kix.dev/*` annotations. No silent bulk deletes.
- [ ] Non-K8s side effects (e.g. Forgejo user creation) — start with execution on "ssh", later crossplane or provider plugins
- [ ] Auto-collect readiness — custom general runtime readiness checks (also outside k8s)
- [ ] Auto-inject package identity labels (hash?, otherwise package name + version, like helm best practice)
- [x] Reconcile mode — `kix deploy --reconcile` re-applies all resources even when the activation identity hash matches, healing drift from manual cluster changes. Converts `Skip` actions to `Apply` after change detection.
- [x] Rollback — `kix rollback <cluster>` finds the most recent Superseded activation, resolves its store path from the local Nix store, and re-applies via the existing reconcile engine. No nix build required. Supports `--dry-run`, `--yes`, `--prune`. Uses `find_most_recent_superseded()` in `activation.rs` and the standard wave-based reconcile loop.
- [x] Rollback history + change summary — `kix rollback --list` is a read-only history view that enumerates Superseded activations with name, identity-hash, timestamp, source store path (`built_via`), `previousActivation` link, and local-store availability; supports `--output json|yaml` for scripting. `SupersededActivation` in `cli/kix/src/cluster/activation.rs` now surfaces `previous_activation` from `status.previousActivation` so the deploy chain can be reconstructed. Before applying, the rollback confirmation modal renders the package-grouped diff via `plan::print_package_plan` against the current Active CR so the operator sees exactly what flips. `v2_discussions/84_m0_m1_implementation_plan.md` §2.
- [ ] Canary rollouts — everything runs in parallel via different hashes; unchanged subsystems are reused (same hash = same resource); update only redeploys what changed
- [ ] Migrations as k8s jobs — defined per package for major version upgrades; package hints whether a major version change is rollback-safe (e.g. postgres: only one version)
- [ ] Rollout pattern as a developer choice — no magical "always works" pattern due to state; stateless deps can duplicate, stateful deps need careful management
  - The system should ideally auto-classify dependencies by statefulness, not just surface the choice
- [ ] Consistent cluster state guarantee — a fully-evaluated, locked cluster state means the entire set of resources is known to be self-consistent. No "helm installed something with a different env var" surprises
- [ ] systemd like features that give you the timings per stage until ready. To understanding what is slowing down deploys etc.

## Graph & observability

> "Since we have content-addressing, we can see a full dependency tree. Not only great for garbage collection, but especially interesting for debugging and cluster reasoning."

- [x] Graph view — visualize the full dependency tree of resources in the cluster
  - `cli/kix-cli/src/commands/graph.rs`: supports dot (graphviz), JSON, and tree output formats. Backend in `cli/kix/src/cluster/graph.rs` using petgraph DAG.
  - Note: this is the structural dependency graph only, not runtime observability. No health/readiness/runtime state.
  - As a debugging confidence tool: "we can't prevent bugs, but we want to very quickly give you confidence in knowing where it is" — reduce time-to-localize, not just time-to-prevent
- [ ] Observability — enrich the graph with runtime health: know what is healthy, degraded, or potentially impaired. Requires integration with monitoring (prometheus, etc.) and cluster health checks to understand consequences of changes.
- [ ] Topology-aware monitoring — auto-generate monitoring configuration (PrometheusRules, ServiceMonitors, Grafana dashboards, Alertmanager inhibition rules) from the dependency graph. Blast-radius alerting, correlated error suppression, dependency-chain health dashboards. The Datadog value prop ("find the problem faster") via compile-time graph analysis. Also: derive service mesh CRDs (Istio/Cilium) from the connection graph, making the mesh thinner. See `v2_discussions/49_topology_aware_monitoring.md`.
- [ ] Garbage collection — unreferenced resources are detectable
- [ ] Cross-service failure debugging — understanding why something failed across many microservices, enriched by the dependency graph

## Tooling & CLI

- [x] `kix logs <cluster> <package>` / `kix pf <cluster> <package> <port...>` — thin wrappers that build the cluster, resolve the package instance to its primary workload (Deployment → StatefulSet → DaemonSet) via `commands/workload.rs::resolve_package_workload`, extract `spec.selector.matchLabels` as a `kubectl -l` selector, and `exec` into `kubectl logs`/`kubectl port-forward`. Forwards `--context`; logs supports `-f/--tail/--since/-c/-p`; pf accepts multiple port specs and `--address`. Deliberately shelling out so the demo is "one tool" without re-implementing streaming. `cli/kix-cli/src/commands/{logs,pf,workload}.rs`, `v2_discussions/84_m0_m1_implementation_plan.md` §4.
- [x] `kix export` — dump all manifests into a human-readable directory structure (`<out>/<namespace>/<Kind>-<name>.yaml`) for use without kix. The exit strategy: "stop using kix at any time, take the YAML." Two modes via `--for`: `exit` (default) strips `kix.dev/*` annotations using the shared `cluster::normalize::strip_kix_annotations` helper and drops kix-internal CRs (Activation, PackageInstance) for a neutral handoff to `kubectl apply` / Flux / Argo; `audit` preserves stamped provenance annotations and kix-internal CRs as M3 compliance-evidence precursor. `cli/kix-cli/src/commands/export.rs`, `v2_discussions/84_m0_m1_implementation_plan.md` §1.
- [ ] `kix init` — scaffold a new cluster definition for a given provider (`kix init --provider gke`). Generates `flake.nix`, cluster definition with flavor preset, and starter packages (ingress, monitoring, cert-manager)
- [ ] CI/CD integration — GitHub Action / GitLab CI template for the plan/apply loop: (a) PR triggers `kix diff`, posts change summary as PR comment (packages changed, resources added/modified/removed, blast radius), (b) merge triggers `kix deploy`. The diff engine and deploy pipeline exist — this is the CI plumbing. Nix binary cache setup guide for fast CI rebuilds. See `v2_discussions/58_satchel_mvp_technical_requirements.md`
- [ ] kix CLI working without installed nix
- [ ] LSP or code smell checks for kix package definitions
- [ ] Rust bridge to nix binary (https://github.com/nixops4/nix-bindings-rust)
- [ ] Allow bringing a values.yaml for helm migration
- [ ] Dry-run / planning mode — "do the builds without the servers"; evaluate what a cluster would look like before hardware exists, as a planning and risk assessment tool ("what would break?")

### Break glass — emergency escape hatches
- [ ] Strip dependency context — remove a resource from the DAG without deleting it (e.g. `builtins.unsafeDiscardStringContext` on a specific dep reference) to unlink a broken dependency and allow the rest of the graph to deploy
- [ ] Force-override a single resource — bypass the content-addressed pipeline for one resource (pin its manifest directly) when the DSL can't express what you need right now
- [ ] Skip a package from the cluster build — `exclude = [ "package-name" ];` at the cluster level to drop a package entirely without editing its definition
- [ ] Partial deploy — deploy a subset of the graph (e.g. only one wave or one namespace) when a broken package blocks the full rollout
- [ ] Escape-hatch annotations — mark resources with `kix.dev/unmanaged: "true"` so kix-diff ignores them, allowing manual hotfixes to coexist temporarily
- [ ] Audit trail for escape hatches — any break-glass action should be visible in the build output / diff summary so it doesn't silently become permanent

### GitOps & operator
- [x] CLI operator mode — `kix deploy/rollback/gc --operator` delegates cluster mutations to the kix-operator via Activation CRs. CLI builds locally, creates/patches CRs, watches status for progress. Operator handles wave-by-wave apply, drift correction, and finalizer cleanup.
- [x] Operator reconcile loop prevention — `observedGeneration` guard skips already-processed generations, all status writes use `patch_status` (status subresource, no generation bump), `record_waves` accumulates wave records in memory to eliminate GET-before-PATCH round-trips. Removed the `reconcile_act_name` hack and blind drift-correction re-apply.
- [x] Trivial GitOps — evaluate nix recipe, when all is built, replace the current hash of the head node
- [ ] kix operator — argo-like nix operator that re-evaluates from git; can reconcile with live cluster state as input variable
  - Inline operators: current cluster state as a pure input — side effects that depend on cluster state can be *configured* (not just executed) in the functional system. This is a general purity capability, not just an operator concern. Solves 90% of operator use cases and can be shipped as part of the package
  - Open question: how does this handle hashes and drift?
- [ ] Feature parity with helm, argo, flux (as a long-term benchmark) — but framed as replacement, not complement: kix eliminates the need for a separate GitOps operator stack

### Advanced deployment
- [ ] PR as its own isolated deployment / fast preview environments — reuse unchanged systems (same hash), everything else gets its own deployment; touching data needs consideration
- [ ] Multi-zone, multi-cluster management — runtime concern for failover, but can model through re-eval with global cluster state variables
  - Client cluster provisioning: backwards compatibility across all clusters is critical; cluster config depends on per-client negotiations
  - Replaces fragile playbooks (Ansible "what changed?" pipelines with unexpected results) with functional, reproducible evaluation
- [ ] Running jobs — install/run separation: "install" produces a derivation with ready manifests, "run" executes with ownership linked to a completing job → fully garbage-collectable

### Vertical integration
> May require bootstrapping an entire ecosystem, not just adding features — potentially not "standalone" (inspiration: Tilt's local dev loop model)
- [ ] Vertical integration with build pipelines (and their hashes) — from source to running container
- [ ] nix-snapshotter — skip Docker entirely
- [ ] Local dev loop — Tilt-inspired watch + rebuild + deploy cycle for fast inner-loop iteration, distinct from GitOps
- [ ] Potentially trivial air-gapped environments
- [ ] Replacing etcd with a nix store (very speculative)
- [x] hardware.nix type file to describe what is raw available and derive helpers, storage, etc etc

### AI & developer experience
- [ ] AI skills: recommended in-kix actions on warnings/errors; skill to read changelogs and derive warnings and checks
- [ ] Code completion and editor integration for the kix DSL

### Permission system

- [ ] enable platform teams and cluster operators to loop in application developers safely

### Service catalog (prebuilt packages)
- [x] kube-prometheus-stack package — monitoring + alerting + Grafana dashboards via `fromHelmChart`. Generic `defaultValues` (sensible resources, open selectors, security context, dashboard sidecar) in `packages/kube-prometheus-stack/`. Cluster-specific overrides (ingress, storage, alertmanager receivers) in cluster definitions. Used in nw1 via `clusters/nw1/monitoring.nix` with CRD builder overlays (`mkServiceMonitor`, `mkPodMonitor`, `mkPrometheusRule`) on `root.out`.
- [ ] Logging stack package — Loki + promtail/fluentbit as kix packages
- [ ] external-secrets-operator package — secret management via external stores (GCP Secret Manager, Vault, AWS Secrets Manager). Standard pattern for secret injection without kix solving secret management itself
- [ ] Prebuilt service catalog completeness — postgres (StackGres, exists), redis/valkey (exists), S3 (exists as mkImport), cert-manager (exists). Gap: no turnkey monitoring or logging

### Terraform coexistence
- [ ] Terraform output → kix import bridge — documented pattern and tooling for consuming Terraform outputs (database URLs, bucket names, service account keys) as kix DI inputs via `mkImport`. Pragmatic scope boundary: kix manages K8s, Terraform manages cloud resources, the bridge connects them. See `v2_discussions/58_satchel_mvp_technical_requirements.md`
- [ ] Long-term: connector/provider abstraction that can wrap Terraform providers, Crossplane XRDs, or raw API calls at compile time. Absorbs cloud resource management into kix evaluation

### Ecosystem & adoption
- [ ] Functional CRDs — deploy against kix, not k8s directly; the end user never needs to think about CRDs/operators. kix evaluates the "need" into manifests (imperative CRD operators replaced by pure evaluation where possible)
  - Stateful operators should stay; pure configuration operators can be absorbed
- [ ] Backbone infra layer — define reuse patterns and cross-service/cross-app logic (e.g. shared storage, common sidecars) to reduce redundancy
- [ ] Service mesh bindings — content-addressed "binds" that translate hashes into public service space; resolves cross-team dependencies at cluster level
- [ ] Backstage as natural evolution — catalog, ownership, libraries

## Case studies & documentation

- [ ] Demo index.html shows `name` and `labels` at top level of `mkResource` without explaining that the DSL auto-nests them under `metadata` — add a callout or insight box so readers understand this isn't standard K8s structure but a deliberate ergonomic shortcut
- [ ] @luca Immich (from simple to full) — package is functional with DI-driven ingress/TLS, extension validation, storage validation, ML worker, metrics. Cluster definitions exist for ludo (homelab) and example. Remaining: document the progression from bare minimum to full production config, auto-derive host from `cluster.domain`.
- [ ] Multi-environment pattern guide — how to set up dev/prod sharing the same packages with different configs (`mkEnv`, separate cluster definitions, branch-based CI deploy). Reference implementation in `clusters/`
- [ ] Exit strategy documentation — clearly document that kix outputs are plain K8s YAML, nothing proprietary runs in the cluster, and `kix export` produces a standalone manifest directory. Address lock-in concerns for startup adoption
- [ ] GKE quickstart — reference cluster definition using GKE flavor, with ingress, cert-manager, monitoring. Verify `lib/flavors/gke.nix` completeness
- [ ] How-to case studies for simple cases
- [ ] Create skill/guide for proper package creation
- [ ] Naming conventions for packages, services, resources, etc.
- [ ] Naming of the project and internals
- [ ] Mocked-up code examples as a design validation tool — "what would the code look like if an engineer used this feature?" Use prospective API sketches to stress-test design decisions before building
- [ ] Intro tutorial as a design artifact — "what would the intro tutorial look like?" is a feedback mechanism for whether the design is understandable, not just a docs task
- [ ] Demo video / README showing the 2-min value pitch:
  - Spin up something with deep dependencies
  - Make a fundamental change and watch it propagate
  - Per-environment overrides (dev: resources /10, staging: no limits, prod: full limits)
  - "You don't have to wipe and restart anymore"
  - Code completion working in the demo
  - "This is what I want" — no separate argo/flux/etc setup needed
- [ ] replacing CI/CD times

## Key risks & design principles

- **Nix adoption barrier** — nix has clear advantages but hasn't taken over the world; we need to actively study *why* people who know about nix's benefits still choose not to use it — not just build features. The intro tutorial and DX must be approachable for a non-nix user. Positioning: nix scales; helm and friends do not.
- **Adoption is the #1 killer of platforms** — not features. The experience for a non-infra developer must be so easy a novice could use it. Datadog vs Prometheus is the cautionary tale (user acquisition beats technical correctness).
- **"Not simple, but intuitive"** — the goal isn't to reduce the interface, but to distill inherent complexity into intuitive form. If the tool is "too smart", the user has to think about the tool rather than their work (mental overhead as a design constraint).
- **Eval times** — content-addressing could lead to long eval times; unclear if path caching helps.
- **Abstraction balance** — narrow interface ≠ less cognitive load; making things simpler than they are creates a dangerous illusion. Don't abstract away physical properties (cost, latency, SLA) — they're leaky abstractions people care about.
- **"Composability and cohesion over capability and completeness"** — the platform will grow by itself, but composability and cohesion must be actively protected.
- **Show value in weeks** — don't over-engineer. Find immediate MVPs and GTM opportunities. The demo must be compelling quickly, not after all features are built.
- **IaC as readable, long-lived intent** — "express ideas in a language you can re-read a year ago". This is a core reason to use nix over YAML/templating: the configuration is human-readable code, not opaque generated output.
