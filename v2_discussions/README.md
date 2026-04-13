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

## Packages, Multi-team, Ownership

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 45 | [Multi-team & operator models](45_multi_team_and_operator_models.md) | RFC | Active | Monorepo vs. federated flakes vs. managed services. **Supersedes the archived `01_evaluateCluster_merging.md` cluster-merging direction.** Open governance questions from 01 are captured in `ROADMAP.md § Open design questions`. |
| 55 | [Shared resource ownership](55_shared_resource_ownership.md) | Open problem | Active | CRD/Namespace ownership in multi-activation clusters; reference counting. |

## Storage, Images, Hardware

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 26 | [Nix-built images (vertical integration)](26_images-vertical-integration.md) | Design | Future-leaning | dockerTools, registry push, nix-snapshotter for supply chain guarantees. Tightly linked to `interesting_thoughts/72_ai_cluster_recipes.md` — the GPU/AI path is where Nix-built images pay for themselves. |
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

> User-facing operator workflow is still an open question — tracked in `ROADMAP.md § Open design questions`.

## Helm / Kustomize / Flux Integration

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 88 | [Kustomize integration](88_kustomize_integration.md) | Design | Near-term | `importKustomization` as build-time resource import for kustomize bases. Same resource-collection API as Helm. Overlays replaced by kix options. |
| 88b | [Flux comparison & migration](88b_flux_comparison_and_migration.md) | Design | Active | Why Flux has runtime reconciliation, feature-by-feature mapping to kix, concrete migration walkthrough from Flux Kustomization CRDs to kix packages. |

> Helm v2 integration is **shipped** — see archived `87_helm_integration_v2.md` and `86_helm_dag_reconstruction.md` for the design record.

## Network Policy

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 92 | [Declarative network policy intents](92_declarative_network_policy_intents.md) | RFC | Near-term | Enforcer-agnostic policy intents declared by flavors/packages/cluster config, materialized by the enforcer through CRD refs. Replaces hand-rolled Cilium CRs in `kind-system-netpol` and `network-policies`. |
| 94 | [DNS dependency chain — step 2](94_dns_dependency_chain_step2.md) | Partial | **Active** | Step 1 rework landed: DNS deps derived from per-workload service-edge detection (shared with netpol), not blanket injection. Step 2 pending: instance-level `extraDeps` for platform-dns → kind-system-netpol link. |
| 95 | [Netpol build-time validation](95_netpol_build_time_validation.md) | Draft | Near-term | Catch missing/misconfigured network policies at eval time: intent schema validation, webhook ingress detection, uncovered port warnings. |
| 96 | [Netpol autogeneration blindspots](96_netpol_autogeneration_blindspots.md) | RFC | **Active** | Three classes of workloads where store-path context analysis fails: Helm charts, operator-managed pods, ConfigMap indirection. Problem analysis + design space for fixes. |

> Netpol auto-derivation (37, 82, 83, 85) is **shipped** — see `archive/` for the design record.

## MVP, Init, Roadmap

| # | Document | Status | Relevance | Summary |
|---|----------|--------|-----------|---------|
| 58 | [Satchel MVP requirements](58_satchel_mvp_technical_requirements.md) | Draft | Near-term | Sam (alpha tester) requirements on GKE/Terraform; maps needs to kix gaps. |
| 64 | [Init & CI concerns](64_init_and_ci_concerns.md) | Draft | Active | How a new user gets bootstrapped and how kix plugs into CI pipelines. (Previously "MVP implementation approach" — MVP framing obsolete, CI/init content still relevant.) |
| 66 | [Milestone roadmap](66_milestone_roadmap.md) | Draft | Active | Five user archetypes, cumulative milestones. |
| 90 | [Ludo as north star — ideation & prioritization](90_ludo_north_star_ideation.md) | Brainstorm | **Active** | Option space + L1–L8 stories for pushing the ludo demonstrator. Kind-only horizon (prod profile, backup contract, first migration pair, gateway switch) then on-device horizon (maintenance, upgrade cascade, CNPG swap, operator self-host). Seeds 4 spin-off sessions. |
| 91 | [CI/CD organizational patterns](91_cicd_organizational_patterns.md) | Design | Near-term | How CI/CD works when a compiler is the integration point. NixOS activation analogy, systemPackages model (app teams publish, operators import), compilation granularity (dependency-scoped + transaction), shift-left self-service, Flux as complementary layer. |

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
