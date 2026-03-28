# v2 Design Discussions

Active design documents for unimplemented features. Implemented, superseded, and reference-only docs are in `archive/`.

## DSL & Package System

- [01 — Cluster merging](01_evaluateCluster_merging.md) — multi-team cluster definition merging before fixpoint
- [22 — Secrets DI](22_secrets_di.md) — secrets as first-class DI resources with producer model
- [25 — Package meta](25_package_meta_warnings.md) — k8s version constraints, warnings, assertions
- [26 — Nix-built images](26_images-vertical-integration.md) — dockerTools, registry push, nix-snapshotter
- [40 — Composite packages](40_composite_packages.md) — decompose Helm bundles, single-package abstraction
- [42 — Dep config injection](42_dep_config_injection.md) — consumers push config into dependency packages

## Wiring & Policies

- [32 — Volume mount DSL](32_volume_mount_dsl.md) — mount `.path` exposure, `.mountAt` on resources, volume dedup
- [35 — CRD-derived RBAC](35_crd_derived_rbac_webhooks.md) — auto-derive RBAC and webhooks from CRDs
- [37 — DI-derived NetworkPolicies](37_di_derived_network_policies.md) — NetworkPolicies from DI graph, no separate connection abstraction
- [38 — Resource type tags](38_resource_type_tags.md) — eval-time type safety (headless service detection etc.)
- [48 — System contracts](48_system_contracts.md) — DI for service deps, capability checks for runtime

## Compiler & Evaluation

- [29c — Compiler design](29_compiler-design.md) — kix compiles K8s wiring, Nix store as IR (reference doc)
- [36 — Rust oracle](36_rust_oracle_at_fixpoint.md) — Rust as active participant during Nix evaluation

## Deploy, Operator & Lifecycle

- [28 — GitOps deploy](28_gitops_deploy.md) — reconciliation, lifecycle, health, observability (M1 complete, M2+ open)
- [29b — Deploy gaps](29b_deploy_implementation_plan.md) — ~90% complete, remaining: GC improvements, annotate.py cleanup
- [43 — Activation operator](43_activation_operator.md) — core design, engine complete, operationalization remaining
- [44 — Operator remaining work](44_operator_remaining_work.md) — OCI transport, drift detection, controller runtime
- [46 — Thin operator plan](46_thin_operator_production_plan.md) — OCI artifacts, capability-based deploy, production readiness
- [50 — CRD upgrades](50_operator_crd_upgrades.md) — upgrade strategy via dependency ordering + content hashing

## Observability & Monitoring

- [49 — Topology-aware monitoring](49_topology_aware_monitoring.md) — auto-generate Prometheus/Grafana from dep graph

## Multi-team & Production

- [01 — Cluster merging](01_evaluateCluster_merging.md) — (also listed under DSL)
- [45 — Multi-team models](45_multi_team_and_operator_models.md) — monorepo vs federated flakes vs managed services
- [45hw — Cluster hardware profile](45_cluster_hardware_profile.md) — provider, capabilities, topology (like hardware.nix)
- [47 — Air-gapped deploys](47_air_gapped_deploys.md) — structured images, closure completeness

## Archive

`archive/` contains implemented, superseded, and reference-only docs:
- **00-10** — v2 foundation: Merkle DAG, fixpoints, instances, DI, namespaces, CRDs, team DX
- **11** — Infrastructure DI (pattern implemented organically)
- **12-20** — Module system iterations (approaches A-D, none adopted)
- **21** — CRD support (partially implemented, builders work)
- **23** — Package structure folders
- **24** — PackageInstance wiring
- **27** — Auto-instantiation (implemented: availablePackages, computeAutoInstances)
- **29** — Deploy architecture (implemented)
- **30, 33, 34** — Connection graph series (superseded by 37's simpler DI-derived approach)
- **39** — DI-driven defaults (immich pattern implemented, not formalized)
- **41** — Deps from args (implemented: normalizePackage, discoverBuildDeps)
- **51** — Merkle health check design (tracked in ROADMAP)
