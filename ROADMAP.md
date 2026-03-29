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
  - [x] **DI-driven defaults** (immich): ingressNginx injected → auto-create ingress (no `enabled` flag); clusterIssuer injected → auto-enable TLS. className derived from `ingressNginx.out.ingressClassName`. TLS secret name auto-derived.
  - [x] **DI-driven defaults** (remaining): applied to n8n, metabase, harbor, python-app (shopfront/ledgerly), velero. Prometheus DI gates ServiceMonitor creation in immich, harbor, coredns. `cluster.domain` provides default host (`"${instanceName}.${cluster.domain}"`). S3 object storage as `mkImport` with explicit `out` (hetzner-s3, ovh-s3 in nw1). Velero exposes `out.withBackup`/`out.withoutBackup` transformers. StackGres takes `storageClasses ? null` for storage DI. See `v2_discussions/39_di_driven_defaults_design.md`.
  - [x] **Auto-instantiation from default package set**: `availablePackages` in `modules.nix` is the cluster-level registry; `computeAutoInstances` in `eval/auto.nix` uses `builtins.genericClosure` for transitive reachability — when a hard dep has no matching instance, it is auto-created from the registry. Also activates `optional` instances when depended on. Resolution order: (1) match concrete instance in cluster, (2) fall back to alias, (3) auto-instantiate from default package set.
  - (pot nonsense:) Two-tier model: auto-enable if a dependency exists in the cluster; explicit enable triggers full transitive pull-in of everything needed
  - [x] Packages can declare **default aliases** alongside their options and builders (e.g. cert-manager aliases `clusterissuer`), so dependencies can resolve against general capabilities, not just package names — `meta.defaultAliases` on the package; `effectiveAliases` / `peekPackageAliases` in `meta.nix` merge package-declared and instance-level aliases
  - [x] The available package list for auto-resolution must live under a **dedicated config path** — `availablePackages` option in `modules.nix`; accepts raw package functions or `{ package, namespace?, aliases? }` attrsets
- [x] v2_discussions/11 → injecting storage, certs, and other infra items from the cluster graph (different package types?)
  - Storage DI: PVCs are first-class instances in the cluster definition (packages/persistent-volume-claim). storage-classes exposes `out.storageClassName`. Consuming packages (e.g. immich) take `storage` as a hard DI dep, mount via `storage.out.name`. Package `meta` (lifecycle, scope) enables cross-namespace validation and kix-diff protection.
- [x] Use "already existing" cluster elements — `kix.mkImport { from = package; }` evaluates packages in import mode (lightweight `mkImportResource`, no store paths) to derive `out` properties for DI resolution. Deployed as a marker PackageInstance CR only.
  - [ ] kix deploy should verify imported resources actually exist in the live cluster
- [ ] Default metadata scoping — which resources should global metadata apply to? Not higher-order resources like Deployments/Services, but what about CRDs?
- [ ] Non-manifest side effects — external imperative actions (e.g. creating a Forgejo user, provisioning a DNS record) as first-class graph nodes alongside manifests. kix deploy resolves these as tasks, not resources. Later feature — requires extending the graph model beyond K8s manifests
- [ ] "Wire" vs "compose" coherence — sharing selectors by reference can copy wrong state if labels are accessed; post-processing breaks composition. Needs a principled solution
- [ ] Higher-level abstractions must "imprint" on resources — all relevant information from higher-level logic should be visible on the underlying K8s resource for auditability and tooling
- [ ] Dynamic duplicate dependencies — the same resource (e.g. a second CoreDNS) can be pulled in twice; deduplication is the consumer's responsibility, not the creator's
- [ ] mkManifest pre-creation hook as escape hatch — global function hook for raw access to any resource before it becomes a manifest
- [x] CRDs, creation and basic usage — `mkCRDRef` creates CRD references with auto-generated `mkCR` builders; used by cert-manager, stackgres, monitoring packages
  - [ ] CRD schema management, verification against live cluster, and import from existing CRD definitions
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

- [ ] Security defaults via mkDefault — e.g. all pods non-root by default, users must mkForce to override
  - mkForce as an auditable signal: any use of mkForce to override security defaults can be flagged, surfaced in review, or blocked by policy
  - The full nix module priority hierarchy (mkDefault → normal → mkOverride → mkForce) is what makes multi-team cluster configs maintainable at scale
- [ ] CVE tracking — integrate with NixOS security tracker (https://tracker.security.nixos.org/suggestions/) for awareness of vulnerabilities in dependencies
- [ ] Automated compliance — continuous verification against regulatory frameworks (SOC2, HIPAA, PCI-DSS)
- [ ] Secret handling and injection (agenix, etc.) — hashes of encrypted secrets don't trigger spurious changes; injection happens in kix-deploy
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
- [ ] Flavor-provided DI imports for system services — flavors must provide `mkImport` instances for platform-managed services (`dns`, `storageClasses`, `ingressController`). Currently flavors only set capabilities; they don't contribute to the DI graph. Requires flavors to have access to `kix.mkImport` via specialArgs. See TODO annotations on `ingressController`, `persistentStorage`, `cni`, `networkPolicyAPI`, `rwxStorage`, `volumeSnapshots` in `lib/modules.nix`.
- [ ] Auto-injected DNS dependency — post-evaluation pass (like `lib/netpol.nix`) that detects FQDN references in resources and auto-adds a store-path edge to the `dns` DI provider. Ensures correct deploy ordering and build-time error if no DNS provider exists. Packages with `meta.defaultAliases = ["dns"]` (e.g. coredns) satisfy this automatically.
- [ ] Post-eval verification for Helm imports — scan resources from `fromHelmChart` for implied prerequisites (PVCs without `storageClasses` provider, Ingress without `ingressController`, LoadBalancer without capability). Safety net for opaque resource sets that bypass DSL-level DI wiring.
- [ ] Migrate capability TODOs to DI — several capabilities are marked for DI migration in `lib/modules.nix`: `ingressController` → DI dep with `out.ingressClassName`; `cni` / `networkPolicyAPI` → CNI as DI dep with `out.networkPolicyAPI`; `rwxStorage` → storage provider `out.accessModes`; `volumeSnapshots` → snapshot controller DI dep.

## Platform capabilities (module-level features)

> "If Prometheus is already there, why not auto-enable it in CoreDNS?"

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
- [ ] Builder/transformer placement — should package builders (`withCert`, `mkCertificate`) live on `out` (via `main.out`) or on parts directly? Current: `main.out` for DI-visible transforms, parts for package-internal helpers like `mkCertificate`. Storage uses plain values (`out.storageClassName`) rather than transformers. Needs a clear convention as more infra packages expose builders
- [ ] Remove `outputs` design — custom `outputs` on `mkResource` is a bolted-on escape hatch; port, fqdn, and other DI-visible values should be auto-derived or come from a richer `out` model, not manual string declarations per resource. `main.out` (package-level out) partially addresses this — it allows complex types (lists, functions) beyond stringified resource outputs (e.g. stackgres-cluster exposes `out.extensionNames` as a list, cluster-issuers exposes `out.withCert` as a function). But per-resource `outputs` still exists for simple string values like port.
- [ ] Port wiring logic — carry port information up through container → pod → service → ingress; prevent wiring things that don't have a route
- [ ] Functional composition as correctness — "this service wraps this app, this HPA wraps this app, you figure out the rest"; correct wiring emerges from composition, not from template deduplication
- [ ] Image convention — `"${config.image.repository}:${config.image.tag}"` + `imagePullPolicy` is repeated in every package. Standardize as a single option (full image string or structured with a helper) so packages don't each reinvent image construction
- [x] Better CoreDNS corefile handling
  - `packages/coredns/helpers.nix`: structured Corefile generation with `renderPlugin()`, `renderServerBlock()`, `renderSnippet()`, `mkCorefile()`, and `defaultServer` definitions. Structured server definitions via package options.
- [ ] Full CoreDNS binary building
- [ ] selector based on "identity" to say "i want this and exactly this resource"

## Post eval validation (kix validate)

- [ ] OpenAPI schema validation at build time — K8s resources have a known openAPI spec, verify against it during eval


## Drift detection & diffing (kix diff)

- [x] kix-dump — normalize and dump live cluster state
- [x] kix-diff — compare kix output against dump (summary, renames, modified, identical)
- [x] Diff on instance level (grouped by package instance)
  - `cli/kix-cli/src/plan.rs`: `diff_graphs()` groups by `(namespace, instance_name)`. Python version in `tools/kix-diff/kix-diff.py`: `diff_packages()` returns grouped diffs by package key.
- [x] Diff on resource level (individual resource changes)
  - `cli/kix-cli/src/plan.rs`: `diff_package_resources()` produces per-resource diffs via `PackageChangeDiff.resource_diffs`. Python version in `tools/kix-diff/kix-diff.py`: `diff_manifests()` with per-resource output.
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
- [x] `kix gc` — garbage-collect orphaned kix-managed resources against a cluster's expected manifest set
- [ ] `kix gc` without cluster eval — GC purely from live Activation/PI graph (no nix eval required)
- [ ] Non-K8s side effects (e.g. Forgejo user creation) — start with execution on "ssh", later crossplane or provider plugins
- [ ] Auto-collect readiness — custom general runtime readiness checks (also outside k8s)
- [ ] Auto-inject package identity labels (hash?, otherwise package name + version, like helm best practice)
- [x] Reconcile mode — `kix deploy --reconcile` re-applies all resources even when the activation identity hash matches, healing drift from manual cluster changes. Converts `Skip` actions to `Apply` after change detection.
- [x] Rollback — `kix rollback <cluster>` finds the most recent Superseded activation, resolves its store path from the local Nix store, and re-applies via the existing reconcile engine. No nix build required. Supports `--dry-run`, `--yes`, `--prune`. Uses `find_most_recent_superseded()` in `activation.rs` and the standard wave-based reconcile loop.
- [ ] Canary rollouts — everything runs in parallel via different hashes; unchanged subsystems are reused (same hash = same resource); update only redeploys what changed
- [ ] Migrations as k8s jobs — defined per package for major version upgrades; package hints whether a major version change is rollback-safe (e.g. postgres: only one version)
- [ ] Rollout pattern as a developer choice — no magical "always works" pattern due to state; stateless deps can duplicate, stateful deps need careful management
  - The system should ideally auto-classify dependencies by statefulness, not just surface the choice
- [ ] Consistent cluster state guarantee — a fully-evaluated, locked cluster state means the entire set of resources is known to be self-consistent. No "helm installed something with a different env var" surprises

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
- [ ] Trivial GitOps — evaluate nix recipe, when all is built, replace the current hash of the head node
- [ ] kix operator — argo-like nix operator that re-evaluates from git; can reconcile with live cluster state as input variable
  - Inline operators: current cluster state as a pure input — side effects that depend on cluster state can be *configured* (not just executed) in the functional system. This is a general purity capability, not just an operator concern. Solves 90% of operator use cases and can be shipped as part of the package
  - Open question: how does this handle hashes and drift?
- [ ] feature parity with helm, argo, flux

### Advanced deployment
- [ ] PR as its own isolated deployment / fast preview environments — reuse unchanged systems (same hash), everything else gets its own deployment; touching data needs consideration
- [ ] Multi-zone, multi-cluster management — runtime concern for failover, but can model through re-eval with global cluster state variables
  - Client cluster provisioning: backwards compatibility across all clusters is critical; cluster config depends on per-client negotiations
  - Replaces fragile playbooks (Ansible "what changed?" pipelines with unexpected results) with functional, reproducible evaluation
- [ ] Feature parity with helm, argo, flux (as a long-term benchmark) — but framed as replacement, not complement: kix eliminates the need for a separate GitOps operator stack
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

### Ecosystem & adoption
- [ ] Functional CRDs — deploy against kix, not k8s directly; the end user never needs to think about CRDs/operators. kix evaluates the "need" into manifests (imperative CRD operators replaced by pure evaluation where possible)
  - Stateful operators should stay; pure configuration operators can be absorbed
- [ ] Backbone infra layer — define reuse patterns and cross-service/cross-app logic (e.g. shared storage, common sidecars) to reduce redundancy
- [ ] Service mesh bindings — content-addressed "binds" that translate hashes into public service space; resolves cross-team dependencies at cluster level
- [ ] Backstage as natural evolution — catalog, ownership, libraries

## Case studies & documentation

- [ ] Demo index.html shows `name` and `labels` at top level of `mkResource` without explaining that the DSL auto-nests them under `metadata` — add a callout or insight box so readers understand this isn't standard K8s structure but a deliberate ergonomic shortcut
- [ ] @luca Immich (from simple to full) — package is functional with DI-driven ingress/TLS, extension validation, storage validation, ML worker, metrics. Cluster definitions exist for ludo (homelab) and example. Remaining: document the progression from bare minimum to full production config, auto-derive host from `cluster.domain`.
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
