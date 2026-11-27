# 62: Operator Production — Implementation Plan

**Status:** Implementation plan (decision foundation)
**Consolidates:** `44_operator_remaining_work.md` (mostly absorbed), `46_thin_operator_production_plan.md` (partially absorbed)
**Related:** `43_activation_operator.md`, `58_satchel_mvp_technical_requirements.md`, `45_multi_team_and_operator_models.md`

---

## Current state

The operator engine is functionally complete. Specifically, everything doc 44 proposed under "Controller Runtime" and "Drift Detection" is implemented:

| Capability | Status | Location |
|---|---|---|
| Reconcile engine (extracted, observer-based) | Done | `kix/src/cluster/reconcile.rs` |
| Drift detection (normalize + content hash) | Done | `kix/src/cluster/normalize.rs` |
| Controller loop (phase lifecycle, generation filter) | Done | `cli/kix-operator/src/controller.rs` |
| Activation lifecycle (Queued→Deploying→Active→Superseded) | Done | `kix/src/cluster/activation.rs` |
| Finalizer-based GC | Done | `cli/kix-operator/src/controller.rs` |
| CLI operator mode (deploy/rollback/gc --operator) | Done | `cli/kix-cli/src/commands/operator.rs` |

**What doesn't exist yet:** OCI transport, container image, deployment manifests, health probes, leader election, metrics, CI integration. The operator works but requires a local Nix store and can't run as a pod.

---

## Phases

### Phase 1: OCI transport — decouple operator from Nix

**Delivers:** The operator can consume manifests from an OCI registry instead of a local Nix store path. This is the fundamental prerequisite for in-cluster operation.

**Code changes:**

1. **`kix artifact push` CLI command** — packages a local activation result dir (`kix-packages.json` + manifest JSONs) as an OCI artifact and pushes to a registry. Start by shelling out to `oras` CLI; native Rust OCI client later if needed.

2. **`ManifestArtifact` loader in `kix/src/eval/`** — `from_oci()` pulls artifact, `from_dir()` loads local. Returns the same `Vec<Value>` manifest list the engine already consumes.

3. **Source resolution in controller** — `controller.rs` currently calls `source_path()` which reads `spec.source.path`. Add `ActivationSource::Oci { reference, pull_secret }` variant. The reconcile path becomes: resolve source → load manifests → detect changes → waves → apply.

4. **Artifact caching** — on-disk cache keyed by OCI digest so the operator doesn't re-pull on every requeue.

**Open questions (see [OQ1](#oq1), [OQ2](#oq2), [OQ3](#oq3))**

**Unblocks:** Phase 2 (container image), Satchel MVP Phase 3 (CI integration — `58_satchel_mvp_technical_requirements.md` §1).

---

### Phase 2: Container image + deployment manifests — run in-cluster

**Delivers:** The operator runs as a pod in `kix-system`, managing the cluster it lives in.

**Code changes:**

1. **Dockerfile** — multi-stage Rust build, distroless base, <50MB. No Nix, no shell. If shelling out to `oras` (Phase 1), bundle it; otherwise pure Rust binary.

2. **Health probes** — `/healthz` (liveness) and `/readyz` (readiness) on port 8080. Minimal HTTP server (axum or hyper).

3. **kix package for the operator** (`packages/kix-operator/`) — Namespace, Deployment, ServiceAccount, ClusterRole, ClusterRoleBinding. Broad RBAC (see 46 §3c for rationale). CRDs applied as wave 0.

4. **Bootstrap story** — first deploy via `kix deploy` (CLI). After that, the operator manages its own upgrades via Activation CR. Document this chicken-and-egg.

**Open question (see [OQ4](#oq4))**

**Unblocks:** Phase 3 (hardening), real multi-team use (`45_multi_team_and_operator_models.md`).

---

### Phase 3: Operational hardening — trust it with real workloads

**Delivers:** Leader election, graceful shutdown, metrics, events. The operator can run in production with multiple replicas and standard observability.

**Code changes:**

1. **Leader election** — kube-rs Lease-based. Only one instance reconciles at a time.

2. **Graceful shutdown** — SIGTERM finishes current wave, records progress, exits. Next instance resumes (wave progress persistence already works).

3. **Concurrency limits** — cap concurrent reconciles (2-3). Per-activation rate limiting.

4. **Prometheus metrics** — `kix_reconcile_total`, `kix_reconcile_duration_seconds`, `kix_activations_active`, `kix_resources_applied_total`. Expose on `:9090/metrics`. ServiceMonitor in the kix-operator package.

5. **Kubernetes Events** — `ReconcileStarted`, `WaveComplete`, `DeployComplete`, `ReadinessTimeout` on Activation CRs via `kube::runtime::events::Recorder`.

**Unblocks:** Satchel MVP confidence, production adoption.

---

### Phase 4: CI integration — close the git-to-cluster loop

**Delivers:** Teams push code, see a diff on PR, merge deploys. This is the Satchel MVP's core CI/CD requirement (`58_satchel_mvp_technical_requirements.md` §1).

**Code changes:**

1. **GitHub Action: diff on PR** — `nix build` → `kix diff` → post summary as PR comment. The diff engine exists; this is plumbing.

2. **GitHub Action: deploy on merge** — `nix build` → `kix artifact push` → `kubectl patch activation` (update OCI reference). The operator reconciles.

3. **Nix cache setup** — docs/tooling for cachix/attic so CI doesn't rebuild from scratch.

**Open question (see [OQ5](#oq5))**

**Unblocks:** Satchel pilot, self-service team adoption.

---

## Open questions

<a id="oq1"></a>
### OQ1: Dependency graph in artifact or derived from manifests?

Doc 46 proposes baking a `kix-graph.json` (pre-computed dependency graph) into the OCI artifact, replacing the `nix-store -q --graph` call. But `controller.rs` already builds the graph from manifest annotations (`kix.dev/depends-on`) via `ResourceGraph::from_manifests()` — it doesn't use the Nix store graph at all.

**Question:** Is `kix-graph.json` actually needed? The operator already derives the dependency graph from annotations. The only thing it can't do without the Nix store is resolve *package-level* grouping (which `kix-packages.json` already provides). If `kix-packages.json` + manifest JSONs are sufficient, the artifact format is simpler.

**Impact:** Simplifies Phase 1 significantly if we skip it.

<a id="oq2"></a>
### OQ2: OCI client strategy — oras CLI vs native Rust

Doc 46 suggests starting with `oras` CLI, replacing with `oci-distribution` crate later. Tradeoffs:

- `oras` CLI: fast to implement, but adds a binary dependency to the operator image (contradicts the distroless goal) and to developer machines
- Native Rust (`oci-distribution` or `oci-client`): more upfront work, but the operator stays a single static binary. Auth handling is more complex.

**Decision needed before Phase 1 starts.** Affects Dockerfile design (Phase 2).

<a id="oq3"></a>
### OQ3: Artifact size and registry strategy

For large clusters (500+ resources), artifacts could be 10-50MB of JSON. Options from doc 44:
- Single layer (simplest)
- Per-package layers (enables layer caching in registry)
- Compressed

For MVP, single compressed layer is probably fine. But if Satchel's cluster grows, this matters. **Defer until real usage data exists?**

<a id="oq4"></a>
### OQ4: Operator RBAC scoping

The operator needs `*/*` access because it applies arbitrary resource types. Doc 46 §3c accepts this as intentional. But for multi-team scenarios (`45_multi_team_and_operator_models.md`), should we design for namespace-scoped operators from the start?

**Tradeoff:** Broad RBAC is simpler and matches the single-operator-per-cluster model. Namespace scoping adds complexity but may be required for enterprise adoption. The Satchel MVP doesn't need it.

<a id="oq5"></a>
### OQ5: Push-based vs operator-based deploy for Satchel MVP

Doc 58 §OQ3 asks: should the MVP use the operator for continuous reconciliation, or simple CI-triggered `kix deploy`?

- CI-triggered deploy (no operator in-cluster): simpler, fewer moving parts, matches Sam's Terraform mental model
- Operator-based: needs Phases 1-3 complete, but enables drift correction and status visibility via CRs

**This determines whether Phases 1-3 are on the critical path for Satchel, or whether CI-triggered CLI deploy is sufficient for the pilot.**

---

## What happens to docs 44 and 46

**Doc 44** (`44_operator_remaining_work.md`): Sections 3 (Drift Detection) and 4 (Controller Runtime) are fully implemented — the doc is stale. Section 2 (Manifest Artifact) and Section 6 (Open Questions) are partially superseded by this plan and by 46's more detailed design. **Archive it** — the remaining useful content (OCI artifact design, SSA fieldsV1 discussion) is captured here or in 46.

**Doc 46** (`46_thin_operator_production_plan.md`): Contains the detailed implementation specs for all phases above (artifact format, controller changes, Dockerfile, RBAC, health probes, leader election, metrics, CI workflows). **Keep it as the detailed reference** — this plan sequences the work and surfaces decisions, 46 has the implementation details.
