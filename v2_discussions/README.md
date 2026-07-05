# v2 Design Discussions

Active design docs for kix v2. After the April 2026 cleanup this folder is aggressively scoped to **open thoughts only**: anything implemented, superseded, or reference-only has moved to `archive/`; anything "future / curious / not blocking current work" has moved to `interesting_thoughts/`.

> **For AI agents:** Read this index first. Don't `ls` the folder — use the **relevance** column and the groupings below to decide what's worth opening.

## How to read this index

Docs are tagged on two axes:

| Axis | Values | Meaning |
|---|---|---|
| **Status** | Design, RFC, Draft, Open question, Reference, Brainstorm | How cooked the thinking is. |
| **Relevance** | **Active**, **Near-term**, **Future**, **Reference** | How close this is to current work. |

**Relevance glossary:**

- **Active** — currently being built or actively debated; touch this before changing adjacent code.
- **Near-term** — on the roadmap's shortlist, design largely done, implementation pending.
- **Future** — valuable ideas with no near-term pressure (lives in `interesting_thoughts/`).
- **Reference** — keep-forever context, not a work item (conceptual anchors, migration playbooks).

If you are planning an implementation, read **Active** and **Near-term** docs in the relevant section. If you are exploring a new feature area, also skim the **Reference** doc in that section. Only read **Future** docs when the user explicitly asks about that horizon.

---

## Compiler & DSL

Core language, evaluation model, wiring primitives.

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 29 | [Compiler design](29_compiler-design.md) | Reference | **Reference** | Conceptual anchor: kix compiles K8s wiring, Nix store as IR. Implementation sketches are stale but the core framing is the single best starting point for any technical topic. |
| 31 | [Port fanout DSL](31_port_fanout_dsl.md) | Design | Near-term | Port registry to eliminate repeated port declarations across K8s resources. |
| 32 | [Volume mount DSL](32_volume_mount_dsl.md) | Partial | Active | Mount `.path` exposure, `.mountAt` on resources, volume dedup. Read alongside `63a` for the cluster-side story. |
| 35 | [CRD-derived RBAC & webhooks](35_crd_derived_rbac_webhooks.md) | Proposal | Near-term | Auto-derive RBAC rules and webhooks from CRD definitions. |
| 40 | [Composite packages](40_composite_packages.md) | RFC | Near-term | Decompose Helm bundles (kube-prometheus-stack etc.) into single-package abstractions. *Use case is still fuzzy — open question which real bundle validates this.* |
| 65 | [Passthrough instances](65_passthrough_instances.md) | Draft | Near-term | Instances that participate in DI but produce zero K8s resources (S3, databases, DNS). *Use case is still fuzzy — waiting on a concrete driver.* |
| 73 | [Workloads, jobs, ad-hoc compute](73_workloads_jobs_and_ad_hoc_compute.md) | Brainstorm | Near-term | Enable kix compilation of Jobs (RayJob, PyTorchJob) via dependency graph wiring. |
| 80 | [Structured diagnostics](80_structured_diagnostics.md) | Design | Active | Structured warnings/errors/traces with src attribution, deferred + fatal modes, sidecar JSON + stderr marker transport to CLI. |
| 100 | [Package DSL ergonomics survey](100_package_dsl_ergonomics_survey.md) | Brainstorm | **Active** | Cross-cutting inventory of package-authoring pain points mapped against existing `kix/lib` support. Classifies each as abstraction-vs-code-saver and proposes concrete hook points. Seeds RFCs for `scope.mkIdentity`, `scope.mkWebhookService`, `scope.mkOptional`, capability contracts, `workload.out.ports`. |
| 120 | [Compiler-theory mapping](120_compiler_theory_mapping.md) | Analysis/Brainstorm | **Active** | Maps kix structures onto named compiler concepts (weak/strong symbols, legalization, canonicalization, translation validation, two-phase compilation, unsafe-visibility) and lists under-explored compiler surfaces: link-time typing of DI `out` contracts (biggest gap), field-level provenance ("kix explain"), batch diagnostics with recovery points (extends 80), incremental eval (corrects 29's caching claim — IFD/helm caching first), ABI versioning of `out`, compiler-grade testing (differential/snapshot/fuzz), apiVersion+CR-schema legalization passes. States non-goals: no optimization, no smart runtime. |
| 119 | [Core surface audit](119_core_surface_audit.md) | Analysis/Draft | **Active** | Readiness × necessity audit of the `guide/00-ideas.md` principles against `kix/lib` code + a 60-package usage census, from the package-author's seat. Ring model for an open-sourcable core (essence: store-path-as-edge, `out`, K8s-shaped, refusals; layers: netpol, helm, scorecard, capability ownership). Flags zero-usage surfaces (`mkOptional`, `mkWebhookService`, `kix.monitor`, `out.url/ports`), Cilium-baked netpol envelope, off-by-default essence rules, and the authoring sharp-edge list as the OSS-core gate. Includes a grammar-vs-vocabulary DSL taxonomy (sealants/queries/edge-words vs derivers/sub-DSLs/behaviors) crossed with guarantee classes G0–G4. |
| 126 | [Compiler core rewrite plan](126_compiler_core_rewrite_plan.md) | Design/Plan | **Active** | Sequences 119/120/121 into an executable rewrite program: make the ring model a physical file-and-contract boundary with 121's hooks as the attachment mechanism. Ground rule: content addressing makes every refactor step machine-checkable (empty manifest diff on ludo-kind + nw1-migrated). Six phases (safety net → envelope repair → hooks+netpol plugin → scope.nix decomposition → diagnostics/error codes/always-on essence rules → cut list); freezes the CLI contract and the three-fixpoint architecture; defers link-time `out` typing and doc 115 to after. Exit criteria include the grep test (no netpol reference outside `plugins/`). |
| 115 | [Pod-spec hardening pass](115_pod_spec_hardening_pass.md) | RFC/Design | **Active** | Cluster-level `cluster.podHardening.profile = "baseline" \| "restricted"` (PSA vocab, §8). Two interception points mirror existing kix patterns: native workloads merged pre-`toFile` in `scope.mk*` (the `netpol.buildWorkloadCnps` slot), Helm-imported workloads merged pre-wrap in `importChart` (the `helm-dag.nix` slot). Author values win per-field, `architecture.hardeningWeakened` scorecard rule fires on weakening (§7 escape hatch + §6 actionable diagnostic). Rejects `meta.hardening` (§13), runtime PSA admission (§4), opt-in `kix.harden` (§11). Defers anti-affinity + resource defaults (not PSA). |

## Packages, Multi-team, Ownership

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 45 | [Multi-team & operator models](45_multi_team_and_operator_models.md) | RFC | Active | Monorepo vs. federated flakes vs. managed services. **Supersedes the archived `01_evaluateCluster_merging.md` cluster-merging direction.** Open governance questions from 01 are captured in `ROADMAP.md § Open design questions`. |
| 55 | [Shared resource ownership](55_shared_resource_ownership.md) | Open problem | Active | CRD/Namespace ownership in multi-activation clusters; reference counting. |
| 117 | [Self-service platform interface](117_self_service_platform_interface.md) | RFC | Near-term | Self-service on a compiler: schemas compiled from module options (no second type system), golden paths as partially-applied packages, JSON instance files + `loadInstances`, request lifecycle = PR lifecycle, agents consume the same exported schema as tools. First Kro treatment in the corpus; versioning dissolves into repo-atomic commits; two-tier validation (generated schema for speed, warm real eval for truth, language-server style); day-2 read-back framed as an assembly gap; operator-as-request-channel promoted to an open question. |

## Storage, Images, Hardware

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 26 | [Nix-built images (vertical integration)](26_images-vertical-integration.md) | Design | Future-leaning | dockerTools, registry push, nix-snapshotter for supply chain guarantees. Now also covers BGP routing as a capability contract unlocked by node-image ownership (one `cluster.bgp` → frr/bird config + cilium/metallb CRs). Tightly linked to `interesting_thoughts/72_ai_cluster_recipes.md`. |
| 63a | [Storage as a cluster concern](63a_storage_as_cluster_concern.md) | Design | Near-term | Storage choice is the cluster operator's concern, not the package author's. Read together with `32_volume_mount_dsl.md` for the full storage+mount story. |

> Note: `45_cluster_hardware_profile.md` has been archived (built). Expect follow-up hardware/topology discussions as we touch scheduling — see also `interesting_thoughts/69_hardware_driven_scheduling.md`.

## Secrets (implementation-only; design corpus archived)

The first SOPS flow is being implemented against a minimum viable design. **All design-level secrets docs have been archived but still carry open questions.** The implementation plan has a header that enumerates them.

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 77b | [Secrets implementation plan](77_secrets_implementation_plan.md) | In progress | Active | Deploy-time SOPS hydration in Rust CLI, kind integration test. Header links to archived `74`/`75`/`76`/`77a`/`78` with their open questions — re-read those before extending secrets scope. |

## Flavors & Platform Ordering

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 93 | [Flavor barrier resource](93_flavor_barrier_resource.md) | Design | Near-term | Synthetic `PlatformBarrier` DAG node so flavor-defined infrastructure instances deploy before application workloads. Single convergence point, `infrastructure` bool on instances, phantom resource approach. |

## Operator & Deploy

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 62 | [Operator production implementation plan](62_operator_production_implementation_plan.md) | Plan | **Active** | **The** operator production doc. Supersedes archived 44 and 46. Engine is functionally complete; remaining: OCI transport, container image, deploy manifests, health/leader/metrics, CI. |
| 67 | [Stateful migration orchestration](67_stateful_migration_orchestration.md) | RFC | Near-term | Orchestrating stateful infra changes leveraging the full cluster DAG. |
| 68 | [Migrating a non-kix live cluster](68_migrate_non_kix_live_cluster.md) | Draft | Near-term | Adoption-safe YAML alongside existing Helm/plain workloads. |
| 81 | [Deploy as a kind-aware lifecycle engine](81_deploy_as_lifecycle_engine.md) | RFC | Active | Reframes deploy as a per-kind transition engine: Plan/Transition/Verdict primitives, structured readiness verdicts replacing wall-clock timeouts. Spine for 67/44/50/56. |
| 84 | [M0/M1 implementation plan](84_m0_m1_implementation_plan.md) | Plan | Active | Short-horizon milestone plan. |
| 98 | [Deploy execution topology](98_deploy_execution_topology.md) | Draft | Active | Follow-up to 81 §L2: diff belongs in the planner, not in wave computation; proposes moving execution from wave-barrier to DAG-streaming (nix-output-monitor-style) with waves retained only as a display/grouping axis. |
| 122 | [Runtime content drift — observed-hash design](122_runtime_content_drift.md) | Design | **Active** | Fixes the unwired content-hash system. Declared (build-time) hashes can't match live objects (zero-value omission is Go pointer-vs-`omitempty` info absent from OpenAPI; `stringData`→`data`; quantity canonicalization — measured 14/193 systematic mismatches on ludo); instead stamp `kix.dev/applied-hash` = Blake3 over the **SSA response** projected onto kix's `managedFields` fieldset. Runtime check = same recipe on the live object, no nix build, near-zero apiserver load (watch-driven; contrast Argo/Flux per-resource dry-run — write-path + webhooks); ownership transfer gives field-level attribution (manager + timestamp). Detection-vs-diagnosis split: closure/dry-run only consulted after a flag. Wires `Verdict::DriftDetected`, adds `drifted` planner state, makes `kix health --deep` cluster-only. Implementation: `fieldsv1.rs` projection module, echo-returning apply, bookkeeping-patch stamping, `drift.rs`. P0 shipped (activations patch ran as manager `unknown`). |
| 123 | [Compiled delegation — drift-ignore surface](123_compiled_delegation.md) | Draft | **Active** | Policy layer for 122: **delegation derived only from controllers inside the activation — compiled, never inferred from live state** (rogue HPA = ownership drift). Two patterns split by the seal boundary: authoring-time `autoscale` intent (workload never owns `replicas` — nothing to ignore) and post-seal assembly scan writing `spec.driftIgnore` onto the *target's* PackageInstance (runtime-resolvable via `kix.dev/package` annotations, inside the activation Merkle). Runtime asserts twice: field-side decision table over foreign managedFields entries (exclude only `status` subresource — `/scale` writes are the signal) and controller-side sweep ("unmanaged controller targets managed resource"). Same DSL shape as `kix.expose` (107); rides doc 83b/121 hooks. |
| 111 | [Operator experience](111_operator_experience.md) | RFC | **Active** | Pre-deploy plan as **DAG diff + migration pairs**, with one node-state taxonomy (`changed`/`dep-changed`/`added`/`removed`/`unchanged`) at both resource and package level. Layered views over the same data: summary, version delta, by-package (with `~` for content vs `⤴` for dep-changed + `cause:` pointer), stateful (lifecycle + migration pairs in one place), blast radius (transitive reverse-walk of `cross_deps`), raw DAG. Stateful gate is in-report visual prominence + CI authorship gate (no terminal prompts; partial apply isn't a thing). `kix status` as universal entry point. Halt-and-report failure default with `--rollback-on-failure` opt-in. Sequences the build order for L1–L4 of doc 90. |

> User-facing operator workflow is still an open question — tracked in `ROADMAP.md § Open design questions`.

## Monitoring

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 101 | [Monitoring provider landscape & auto-wiring](101_monitoring_provider_landscape.md) | Brainstorm | Near-term | Survey of prom-operator / kube-prom-stack / VictoriaMetrics / Alloy / OTel / annotation-fallback; common vs provider-specific shape; option space for `meta.monitoring` intent + capability-owned rendering; open questions blocking a design doc (multi-provider support, CR ownership, CRD-less providers). Spun out of doc 100 §D2. |
| 112 | [Backup operationalization — the trust loop](112_backup_operationalization.md) | RFC/Draft | **Active** | Sibling to 108 (the contract). Reframes from "what reads the receipt" to the **capture → store → verify → restore** trust loop. Backups are managed operations producing artifacts you have to *trust* — not observations. Each stage has distinct failure modes, distinct personas-with-distinct-concerns, distinct kix surface. **Capture:** app owns consistency command, platform owns engine matrix, operator owns schedule. **Store:** operator owns destinations + encryption + off-site (app maintainer owns *nothing* here); promotes off-site/encryption/integrity-check to destination capability schema; `architecture.backupOffsite` is the homelab footgun killer. **Verify** (the new stage): three layers — readable / restorable / app-valid; `out.backupRestoreCheck` is the only thing app maintainers can author and platform/operator literally cannot. Scheduled rehearsals via `cluster.backup.rehearsals` write to activation history; `kix rehearse-restore` verb. **Restore:** `kix restore --dry-run` mandatory; discrete-engine `--to` resolution at plan time; every restore is rehearsed-by-construction (same L3 check). Receipt grows `stages.{capture,store,verify,restore}` slice each stage's consumers read. Cross-cutting: secrets rotation, cost, trust artifacts, off-site. Alerts ride 110 as one surface among many, not the spine. |
| 110 | [Alerts as graph resources](110_alerts_as_graph_resources.md) | RFC/Draft | **Active** | Replaces 105 §B2/§B9. Rejects `meta.alerts` (PRINCIPLES §13) and an invented `kind` taxonomy (PRINCIPLES §8). Alerts are runtime scorecards expressed as `PrometheusRule` resources owned by the package that knows the symptom. `scope.mkAlert { severity, expr, ... }` uses the prom-ecosystem-standard `severity` label (`warning`/`critical`/`info`); only kix-specific label is `kix.dev/owner`. Sensible defaults via curated rule library (re-emit `kube-prometheus` and chart-shipped rules), `scope.mkAlerts.<recipe>` helpers (`standardWorkload`, `pvcCapacity`, `serviceProbe` — called from inside owning packages, no DAG walk), and `cluster.alerts.profile = "homelab" \| "production"`. Two flavor packages: `cluster-baseline-alerts` (5 rules nobody else owns) + `alertmanager-routing` (operator-parameterized 3-line `severityMap` → receivers). Appendix A sanity-checks against a real-world prom-rule corpus (~70 alerts). |

## Helm / Kustomize / Flux Integration

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 88 | [Kustomize integration](88_kustomize_integration.md) | Design | Near-term | `importKustomization` as build-time resource import for kustomize bases. Same resource-collection API as Helm. Overlays replaced by kix options. |
| 88b | [Flux comparison & migration](88b_flux_comparison_and_migration.md) | Design | Active | Why Flux has runtime reconciliation, feature-by-feature mapping to kix, concrete migration walkthrough from Flux Kustomization CRDs to kix packages. |
| 116 | [Migration playbook](116_migration_playbook.md) | Draft | **Reference** | Procedural counterpart to 68. Live-K8s migration, kix-side SBOM first (not dump-driven), staged 1→2→3 source-vs-kix stance, 5 phases (SBOM → flavor+globals → flavor capabilities → diff resolution hierarchy → adoption-readiness diff → cutover). Tier 2 `importChart` is the default for helm-sourced components, not a shallow escape hatch. Anti-patterns from nw1 called out explicitly. TF appendix. |
| 117 | [kube-prometheus-stack wrapping validation](117_kube_prometheus_stack_wrapping_validation.md) | Brainstorm (paused) | **Active** | Does Tier 2 helm cover the just-shipped from-scratch rebuild's guarantees? Validates Phase 1a/1b/2/3 against `kix/packages/{prometheus-operator,prometheus,alertmanager,...}` (commit `d79478f`). Merkle DAG: structurally equivalent if `helm-dag.nix` gains 2 patterns (CR-level `spec.serviceAccountName`, `{name,key}` Secret refs). DI lossy pipeline: categories A–G; Phase 2 substring scan covers most; **silent edge loss on sprig transforms (B) + cross-ns `_kix.namespace` policy (D) + implicit-feature deps (G)**. What dies in wrap: RBAC DSL, typed CR builder, per-key Secret validation, cross-ns validator, granular per-component meta. What wrap gains: chart-shipped admission webhooks/PDB/NetworkPolicy/full ClusterRole verbs that the rebuild silently dropped. Paused mid-discussion at strategic Q1: keep rebuild canonical or wrap-replace? Concrete next steps (sprig-transform audit, declared-but-unscanned `deps` diagnostic, helm-dag extensions, side-by-side DAG diff). |

> Helm v2 integration is **shipped** — see archived `87_helm_integration_v2.md` and `86_helm_dag_reconstruction.md` for the design record.

## Network Policy

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 92 | [Declarative network policy intents](92_declarative_network_policy_intents.md) | RFC | Near-term | Enforcer-agnostic policy intents declared by flavors/packages/cluster config, materialized by the enforcer through CRD refs. Replaces hand-rolled Cilium CRs in `kind-system-netpol` and `network-policies`. |
| 94 | [DNS dependency chain — step 2](94_dns_dependency_chain_step2.md) | Partial | **Active** | Step 1 rework landed: DNS deps derived from per-workload service-edge detection (shared with netpol), not blanket injection. Step 2 pending: instance-level `extraDeps` for platform-dns → kind-system-netpol link. |
| 95 | [Netpol build-time validation](95_netpol_build_time_validation.md) | Draft | Near-term | Catch missing/misconfigured network policies at eval time: intent schema validation, webhook ingress detection, uncovered port warnings. |
| 96 | [Netpol autogeneration blindspots](96_netpol_autogeneration_blindspots.md) | RFC | **Active** | Three classes of workloads where store-path context analysis fails: Helm charts, operator-managed pods, ConfigMap indirection. Problem analysis + design space for fixes. |
| 97 | [Service contract primitives](97_service_contract_primitives.md) | Design | **Active** | Promote the `mkServiceRef` + facade-with-`requires` patterns (prototyped in stackgres-cluster/stackgres-database) into a named `scope.provideService` contract. Closes blindspot 2 of doc 96, subsumes doc 65's passthrough-instance driver, cuts ~100 lines of boilerplate per package. |
| 109 | [Service CIDR capacity check](109_service_cidr_capacity_check.md) | RFC/Draft | Near-term | Promote the existing `cluster.network.serviceCidr` option into an enforced budget. New scorecard rule counts ClusterIP-consuming Services against CIDR host count; fatal error at 100%, warning at 80% (configurable). Rides doc 80 diagnostics. Network-side sibling of doc 106's capacity-fit check. |
| 121 | [Netpol as a plugin](121_netpol_as_plugin.md) | Design | **Active** | Answers doc 119's "does netpol ship in the OSS core" with the extraction mechanics. Three binding constraints (pre-seal splice — post-pass impossible under content addressing; fixpoint safety of hook inputs; four-channel CNP wiring incl. `forNamespace` parenting + sideband drain). Mechanism: three module-option hooks (`workloadInterceptors`/`instanceProcessors`/`clusterProcessors`), netpol plugin as an ordinary module, doc 115 as the second hook consumer. Edge detection stays core (DNS shares it). Prerequisite: enforcer envelope repair (spec assembly behind `mkPolicy`, `portsToCilium` rename). Generalizes enforcer lookup to `findCapabilityProvider`/`validateProviderInterface` (reusable for docs 108/101). |

> Netpol auto-derivation (37, 82, 83, 85) is **shipped** — see `archive/` for the design record.

## MVP, Init, Roadmap

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 58 | [Satchel MVP requirements](58_satchel_mvp_technical_requirements.md) | Draft | Near-term | Sam (alpha tester) requirements on GKE/Terraform; maps needs to kix gaps. |
| 64 | [Init & CI concerns](64_init_and_ci_concerns.md) | Draft | Active | How a new user gets bootstrapped and how kix plugs into CI pipelines. (Previously "MVP implementation approach" — MVP framing obsolete, CI/init content still relevant.) |
| 66 | [Milestone roadmap](66_milestone_roadmap.md) | Draft | Active | Five user archetypes, cumulative milestones. |
| 90 | [Ludo as north star — ideation & prioritization](90_ludo_north_star_ideation.md) | Brainstorm | **Active** | Option space + L1–L8 stories for pushing the ludo demonstrator. Kind-only horizon (prod profile, backup contract, first migration pair, gateway switch) then on-device horizon (maintenance, upgrade cascade, CNPG swap, operator self-host). Seeds 4 spin-off sessions. |
| 91 | [CI/CD organizational patterns](91_cicd_organizational_patterns.md) | Design | Near-term | How CI/CD works when a compiler is the integration point. NixOS activation analogy, systemPackages model (app teams publish, operators import), compilation granularity (dependency-scoped + transaction), shift-left self-service, Flux as complementary layer. |
| 105 | [Ludo homelab — operational readiness](105_ludo_homelab_operational_readiness.md) | Brainstorm/RFC | **Active** | Operator-side counterpart to doc 90: what's needed to run ludo on a real k3s node (single node, Tailscale-only edge, ZFS-local backups, push alerts). Subsystem inventory + 9-item kix gap list (B1–B9). **Status:** B4 (`boundedResources`) and B7 (`cluster.maintenance` surface) shipped; B1 → 108, B2/B9 → 110, B3 → 107, B6 → designed in 77, B8 → folded into 106. Doc remains the operator checklist + spin-out index. Open: B5 docs, Q2 (drop cert-manager day-1?), Q4/Q5 (operator self-host, multi-team SOPS recovery). |
| 107 | [Overlay-edge exposure (tailscale, firezone)](107_overlay_edge_exposure.md) | RFC/Draft | **Active** | Replaces the `meta.exposure` hack from 105 §B3. Reuses K8s-native vocab (`ingress`/`gateway`/`loadBalancer` DI deps mapping to IngressClass/GatewayClass/loadBalancerClass). Single `kix.expose` call dispatches by service-port shape. Tailscale slots in as ingress + loadBalancer + gateway personalities of one package; firezone gets a small in-cluster controller reconciling Service-LB and a `FirezoneResource` CRD against the firezone API. Multi-edge per cluster deferred to v2. |
| 106 | [kix ops surface — lifecycle verbs & capacity check](106_ops_lifecycle_verbs_and_capacity_check.md) | Brainstorm/RFC | **Active** | Spun out of 105 to keep the operator-checklist view separate from the kix-engine view. Specifies four missing CLI verbs (`bootstrap`, `restore`, `upgrade`, `drift`) on top of activation history (`kix history`) plus a build-time capacity-fit check + `single-node` module. All ride existing primitives (`mkActivation` closure, `cluster.hardware`, structured diagnostics, scorecard rules, kind-rehearsal clusters). Phased roadmap A/B/C with explicit dependencies on docs 62/67/81/105. |
| 125 | [Backup across abstraction levels — state as the contract](125_backup_abstraction_levels_and_state_contract.md) | Brainstorm/RFC | **Active** | Challenges 108 §4's intent schema. Level model L0–L5 (app export / paths / CSI volume / storage service / node host / control plane): same bytes, alternative capture points; cluster shape decides which levels exist, so capture level can't live in the package. Core reframe: packages declare **state facts** (`meta.state`: volume+path classes primary/derived/cache, app-native export contract, quiesce hooks, capture-ordering groups) — not backup intent; cluster declares policy; compiler *lowers* each state item to the best available capture level (doc 120 instruction-selection framing). Debates 5 options (state-facts+lowering / `kix.backup` builder / 108 enum+sweep / storage-attached backupClass / backup-plan-as-compilation-artifact) plus a per-level concrete-engine table (§4b) showing every engine's input needs are a subset of the state-facts vocabulary. **Decision deferred** (first feedback round recorded in §7); one hard constraint: declarative input compiling to ready-made services, never a capture verb. Candidate synthesis kept as a composition to attack: A's semantic, B's `kix.state` build-list surface, C's sweep on 121 hooks, D as L2/L3 engine family, E's typed render targets (k8s-resources \| node-module \| runbook). Flags the L0 "runtime-accreted complement" (kix can compute what git won't regenerate) as a standalone differentiator. |
| 124 | [Ludo backups — requirements & rollout plan](124_ludo_backup_requirements_and_plan.md) | Draft/Plan | **Active** | Concrete, research-grounded (2026-07) backup plan for the real ludo node; concretizes 105 §A2. Data classes (Immich originals = crown jewel; kix regenerates all manifests so only data + keys need backup), failure-scenario requirements, tool verdicts: Velero disqualified on k3s local-path (hostPath PVs), foundation = NixOS host-level restic → external HDD → `restic copy` to B2 (delete-less key), Postgres via Immich's built-in nightly dump (StackGres-native deferred — object storage mandatory, MinIO dead, Garage when needed), K8up as the future 108 Phase 1 engine. 4-stage rollout starting with key custody; feeds engine-matrix + destination-schema findings back into 108 (incl. new "node-level engine" open question). |
| 108 | [Backup as a capability contract](108_backup_capability_contract.md) | RFC/Draft | **Active** | Backup as a typed DI capability paralleling storage (`63a`) and monitoring (`101/102`). `meta.backup` intent on package side (consistency + importance, no schedule/destination), `cluster.backup` flavor wires engines per consistency class, engines implement `out.backupEngine.{render,restore}` (the convention `kix restore` in doc 106 §1.2 already assumes). Engine taxonomy (app-aware / CSI-Velero / restic-k8up), six personas, two scorecard rules (`statefulNeedsBackup`, `backupHasRestore`), 4-phase rollout. Unblocks 105 §B1 and 90 §L2. |

---

## `interesting_thoughts/` — future & exploratory

Docs worth keeping alive but with no near-term implementation pressure. Only read these when the user explicitly asks about the topic, or when you are exploring long-horizon design space.

| # | Document | Why it's here |
|---|----------|---------------|
| 36 | [Rust oracle at fixpoint](interesting_thoughts/36_rust_oracle_at_fixpoint.md) | Rust as active participant during Nix evaluation. Cool idea, no near-term driver. |
| 47 | [Air-gapped deploys](interesting_thoughts/47_air_gapped_deploys.md) | OCI artifact transport, image mirroring, closure completeness. Blocked on demand. |
| 49 | [Topology-aware monitoring](interesting_thoughts/49_topology_aware_monitoring.md) | Auto-generate Prometheus/Grafana/Alertmanager config from the dependency graph. |
| 54 | [Activation signing](interesting_thoughts/54_activation_signing.md) | Cryptographic signing of activation root hash for supply-chain verification. |
| 59 | [Load estimation & demand aggregation](interesting_thoughts/59_load_estimation_demand_aggregation.md) | Shared services size themselves based on aggregate consumer demand from DI graph. |
| 69 | [Hardware-driven scheduling](interesting_thoughts/69_hardware_driven_scheduling.md) | How deeply to model hardware: single-cluster depth vs. fleet-wide breadth. |
| 72 | [AI cluster recipes](interesting_thoughts/72_ai_cluster_recipes.md) | GPU/AI cluster recipes for validated hardware + stack combinations. Linked to `26` (Nix-built images). |
| 83b | [Package-owned scorecard rules](interesting_thoughts/83_package_owned_scorecard_rules.md) | Move capability fingerprints out of `kix/lib/rules/architecture.nix` into the owning packages. Extends the now-archived scorecard rules design. |
| 89 | [Eval operator mode](interesting_thoughts/89_eval_operator_mode.md) | In-cluster `nix eval`: operator pulls git, evals, applies. Pull model, no-CI deploy. |

---

## Archive — still useful context

`archive/` holds implemented, superseded, and reference docs. They're often the best source of design rationale. Reach for them when:

- **You're changing a shipped feature** — the archived doc explains why it was built that way.
- **Someone proposes a rework** — the archived doc may already have considered and rejected the idea.
- **You're writing a new doc on the same topic** — link to the archive entry so future readers can find the history.

### Reference docs you will actually re-read

These are archived because they are implemented or deprecated, but they remain the clearest explanation of their topic:

- **`28_gitops_deploy.md`** — GitOps deploy reconciliation / drift / health design. Superseded operationally by `62` + `88b` but still the best single-file explanation of the deploy philosophy.
- **`60_scorecard_rules_design.md`** — Multi-level policy framework with configurable severity and structured reporting. Built. Read when changing scorecard rules.
- **`61_compliance_exports.md`** — Export formats (SARIF, SBOM, SLSA, OSCAL). Built. Read when adding a new compliance output.

### Recently archived (April 2026 cleanup)

Fully implemented, superseded, or dead-end:

- **01** — evaluateCluster merging → superseded by `45_multi_team_and_operator_models.md`; open governance questions lifted to `ROADMAP.md § Open design questions`.
- **25** — Package meta & warnings → shipped.
- **28** — GitOps deploy → reference (see above).
- **37** — DI-derived NetworkPolicies → shipped.
- **38** — Resource type tags → outdated; residual "could-have-used-typed-constructor" lint idea in `ROADMAP.md § Open design questions`.
- **42** — Dep config injection → shipped.
- **43** — Activation operator → shipped; user-facing workflow open question in `ROADMAP.md`.
- **44** — Operator remaining work → consolidated into `62`.
- **45_cluster_hardware_profile** — shipped; future hardware work will spawn new docs.
- **46** — Thin operator production plan → superseded by `62`.
- **48** — System contracts → shipped / folded into DI + capability checks.
- **50** — Operator CRD upgrades → shipped-ish / folded.
- **51, 52** — Demo plan & implementation todo → shipped.
- **60, 61** — Scorecard rules & compliance exports → shipped (kept as references above).
- **68_mkimport_production_readiness** — shipped.
- **68_prometheus_stack_kix_native** — shipped.
- **70** — Gateway API migration → shipped / folded.
- **71_k9s_plugin** — deferred / not pursued.
- **71_library_extraction** — not pursued.
- **74, 75, 76, 77_secret_access_control_modules, 78** — secrets design corpus; open questions tracked in the `77_secrets_implementation_plan.md` header.
- **79** — Operator readiness edges → resolved with proper requirement management.
- **82, 83_netpol, 85** — Netpol/cilium wiring iterations → shipped; simplification landed.
- **86, 87** — Helm DAG reconstruction + Helm integration v2 → shipped.

### Older archive index

For docs archived before April 2026 (Foundation, module system iterations, early implemented features, connection-graph series, etc.), browse `archive/` directly — the file numbering follows the discussion chronology.
