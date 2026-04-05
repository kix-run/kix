# v2 Design Discussions

Active design documents for kix v2. Implemented, superseded, and reference-only docs live in `archive/`.

> **For AI agents:** Read this index first to find relevant prior art. Don't `ls` the folder — use the themed groups and status markers below to decide what to read.

---

## Compiler & DSL

Core language design, evaluation model, and wiring primitives.

| # | Document | Status | Summary |
|---|----------|--------|---------|
| 29 | [Compiler design](29_compiler-design.md) | Reference | Conceptual anchor: kix compiles K8s wiring, Nix store as IR. Read this first for any technical topic. |
| 36 | [Rust oracle at fixpoint](36_rust_oracle_at_fixpoint.md) | Design | Rust as active participant during Nix evaluation (compiler role at fixpoint). |
| 38 | [Resource type tags](38_resource_type_tags.md) | Design | Eval-time type safety without a formal type system (headless service detection etc.). |
| 31 | [Port fanout DSL](31_port_fanout_dsl.md) | Design | Port registry to eliminate repeated port declarations across K8s resources. |
| 32 | [Volume mount DSL](32_volume_mount_dsl.md) | Partial | Mount `.path` exposure, `.mountAt` on resources, volume dedup. |
| 65 | [Passthrough instances](65_passthrough_instances.md) | Draft | Instances that participate in DI but produce zero K8s resources (S3, databases, DNS). |
| 73 | [Workloads, jobs, ad-hoc compute](73_workloads_jobs_and_ad_hoc_compute.md) | Brainstorm | Enable kix compilation of Jobs (RayJob, PyTorchJob) via dependency graph wiring. |

## DSL — Packages & Dependencies

Package structure, composition, and dependency injection.

| # | Document | Status | Summary |
|---|----------|--------|---------|
| 01 | [Cluster merging](01_evaluateCluster_merging.md) | Design | Merging independent cluster definitions before fixpoint for multi-team. |
| 25 | [Package meta & warnings](25_package_meta_warnings.md) | RFC | Structured metadata: k8s version constraints, deprecations, assertions, aliases. |
| 40 | [Composite packages](40_composite_packages.md) | RFC | Decompose Helm bundles (kube-prometheus-stack etc.) into single-package abstractions. |
| 42 | [Dep config injection](42_dep_config_injection.md) | Plan | Consumers push config requirements into dependency packages. |
| 55 | [Shared resource ownership](55_shared_resource_ownership.md) | Open problem | CRD/Namespace ownership in multi-activation clusters; reference counting. |
| 71 | [Library extraction](71_library_extraction.md) | Draft | Split kix framework from monorepo into standalone consumable library. |

## Wiring & Policies

Automated wiring (network, RBAC, storage) derived from the dependency graph.

| # | Document | Status | Summary |
|---|----------|--------|---------|
| 22 | [Secrets DI](22_secrets_di.md) | Design | Secrets as first-class DI resources with producer model and shape validation. |
| 35 | [CRD-derived RBAC & webhooks](35_crd_derived_rbac_webhooks.md) | Proposal | Auto-derive RBAC rules and webhooks from CRD definitions. |
| 37 | [DI-derived NetworkPolicies](37_di_derived_network_policies.md) | Draft | Auto-generate NetworkPolicies from DI resolution and string context. |
| 48 | [System contracts](48_system_contracts.md) | Partial | DI for service deps + capability checks for compile-time cluster prerequisites. |
| 62a | [Exposure compilation](archive/62a_exposure_as_composable_build_entry.md) | **Implemented** | Composable build entries for service exposure (cert-manager, ingress). Archived. |
| 63a | [Storage as cluster concern](63a_storage_as_cluster_concern.md) | Design | Storage choice is cluster operator's concern, not package author's. |
| 64 | [Secret management](64_secret_management.md) | Draft | Six concerns: definition, injection, provisioning, rotation, access control, transport. |
| 64a | [Secret origins & ownership](64a_secret_origins_and_ownership.md) | Draft | Catalog of seven secret origin types with ownership/consumer patterns. |
| 70 | [Gateway API migration](70_gateway_api_migration.md) | RFC | Migrate from ingress-nginx to Gateway API as standard traffic management. |

## Operator & Deploy

Activation operator, lifecycle, deployment strategies.

| # | Document | Status | Summary |
|---|----------|--------|---------|
| 28 | [GitOps deploy](28_gitops_deploy.md) | Active | Reconciliation, drift detection, health, observability. M1 complete, M2+ open. |
| 43 | [Activation operator](43_activation_operator.md) | Active | Core design and engine complete; operationalization remaining. |
| 44 | [Operator remaining work](44_operator_remaining_work.md) | RFC | OCI transport, drift detection, controller runtime for in-cluster operator. |
| 46 | [Thin operator production plan](46_thin_operator_production_plan.md) | Plan | OCI artifacts, capability-based deploy, production readiness. |
| 50 | [CRD upgrades](50_operator_crd_upgrades.md) | Design | Upgrade strategy via dependency ordering + content hashing. |
| 54 | [Activation signing](54_activation_signing.md) | Design | Cryptographic signing of activation root hash for supply-chain verification. |
| 56 | [Unified operator reconcile](archive/56_unified_operator_reconcile.md) | **Implemented** | Phase-based activation lifecycle (Queued → Deploying → Active → Superseded). Archived. |
| 67 | [Stateful migration orchestration](67_stateful_migration_orchestration.md) | RFC | Orchestrating stateful infra changes leveraging the full cluster DAG. |

## Infrastructure & Scheduling

Hardware profiles, scheduling, cluster capabilities.

| # | Document | Status | Summary |
|---|----------|--------|---------|
| 45 | [Cluster hardware profile](45_cluster_hardware_profile.md) | Partial | `cluster.provider`, capabilities, topology — like `hardware.nix` for clusters. |
| 59 | [Load estimation & demand aggregation](59_load_estimation_demand_aggregation.md) | RFC | Shared services size themselves based on aggregate consumer demand from DI graph. |
| 69 | [Hardware-driven scheduling](69_hardware_driven_scheduling.md) | Exploration | How deeply to model hardware: single-cluster depth vs. fleet-wide breadth. |
| 72 | [AI cluster recipes](72_ai_cluster_recipes.md) | Draft | GPU/AI cluster recipes for validated hardware + stack combinations. |

## Multi-team & Production

Multi-team models, air-gapped deploys, live cluster adoption.

| # | Document | Status | Summary |
|---|----------|--------|---------|
| 45 | [Multi-team & operator models](45_multi_team_and_operator_models.md) | RFC | Monorepo vs. federated flakes vs. managed services. |
| 47 | [Air-gapped deploys](47_air_gapped_deploys.md) | Exploration | OCI artifact transport, image mirroring, closure completeness. |
| 68 | [Live cluster compatibility](68_live_cluster_compatibility.md) | Draft | Adoption-safe YAML alongside existing Helm/plain workloads. |

## Observability & Monitoring

| # | Document | Status | Summary |
|---|----------|--------|---------|
| 49 | [Topology-aware monitoring](49_topology_aware_monitoring.md) | Design | Auto-generate Prometheus/Grafana/Alertmanager config from dependency graph. |
| 68 | [Prometheus stack kix-native](68_prometheus_stack_kix_native.md) | Draft | Migrate monitoring from Helm wrapper to kix-native monitoring module. |

## Compliance & Enterprise

Policy, compliance exports, scoring.

| # | Document | Status | Summary |
|---|----------|--------|---------|
| 60 | [Scorecard rules design](60_scorecard_rules_design.md) | Draft | Multi-level policy framework with configurable severity and structured reporting. |
| 61 | [Compliance exports](61_compliance_exports.md) | Draft | Export formats (SARIF, SBOM, SLSA, OSCAL) for auditors/CI/compliance. |

## Tooling & CLI

Developer tooling, import tools, IDE integration.

| # | Document | Status | Summary |
|---|----------|--------|---------|
| 26 | [Nix-built images](26_images-vertical-integration.md) | Design | dockerTools, registry push, nix-snapshotter for supply chain guarantees. |
| 68 | [mkImport production readiness](68_mkimport_production_readiness.md) | Draft | Make mkImport production-ready with validation and CLI awareness. |
| 71 | [k9s plugin](71_k9s_plugin.md) | Draft | k9s plugins to surface kix package context when browsing live clusters. |

## MVP & Roadmap

Customer-facing planning, demo, milestones.

| # | Document | Status | Summary |
|---|----------|--------|---------|
| 58 | [Satchel MVP requirements](58_satchel_mvp_technical_requirements.md) | Draft | Sam (alpha tester) requirements on GKE/Terraform; maps needs to kix gaps. |
| 64 | [MVP implementation approach](64_mvp_implementation_approach.md) | Draft | Companion to 58: sequences implementation for max value from min work. |
| 66 | [Milestone roadmap](66_milestone_roadmap.md) | Draft | Five user archetypes, cumulative milestones. |
| 51 | [Demo plan](51_demo_plan.md) | Plan | Full lifecycle demo: deploy, change, break, detect, fix, rollback. |
| 52 | [Demo implementation todo](52_demo_implementation_todo.md) | Plan | Implementation tasks for VHS demos from doc 51. |
| 53 | [Demo brainstorm](53_demo_brainstorm.md) | Fragment | Catalog of possible demos by readiness tier. |
| 57 | [Adam management brainstorm](57-adam-management-brainstorm.md) | Fragment | Early brainstorm: dashboards, centralized deploy, audit trails. |

---

## Archive

`archive/` contains implemented, superseded, and reference-only docs. They're still valuable context — check them when working on related topics.

### Foundation (00–10)
- **00** — v2 design consolidated
- **02** — Cluster fixpoint aliasing
- **03** — Package fixpoint resources
- **04** — Namespace scope
- **05** — CRDs & type providers
- **06** — Team DX & multi-deploy
- **07** — Instance design
- **08** — v2 unified RFC
- **09** — v2 RFC summary
- **10** — Merkle DAG package instances

### Module system iterations (12–20)
- **11** — Infrastructure DI (pattern implemented organically)
- **12–20** — Module system design explorations (approaches A–D, none adopted as-is)

### Implemented features
- **21** — CRD support (partially implemented, builders work)
- **23** — Package structure folders
- **24** — PackageInstance wiring
- **27** — Auto-instantiation (`availablePackages`, `computeAutoInstances`)
- **29** — Deploy architecture
- **29b** — Deploy implementation plan (~90% complete)
- **39** — DI-driven defaults (immich pattern)
- **41** — Deps out of package function (`normalizePackage`, `discoverBuildDeps`)
- **51** — Merkle health check design
- **56** — Unified operator reconcile (phase-based lifecycle)
- **62a** — Exposure as composable build entry (phases 0–3)

### Superseded
- **30, 33, 34** — Connection graph series (superseded by 37's DI-derived approach)
- **62** — Exposure compilation (superseded by 62a)
- **63** — Storage compilation (superseded by 63a)
