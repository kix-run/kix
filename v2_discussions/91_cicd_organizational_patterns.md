# 91: CI/CD Organizational Patterns for a Kubernetes Compiler

**Status:** Design / Thought piece
**Related:** `45_multi_team_and_operator_models.md` (operator architecture), `64_init_and_ci_concerns.md` (CI mechanics), `88b_flux_comparison_and_migration.md` (Flux comparison), `29_compiler-design.md` (compiler conceptual anchor), `67_stateful_migration_orchestration.md` (state transitions), `81_deploy_as_lifecycle_engine.md` (lifecycle engine), `55_shared_resource_ownership.md` (multi-activation ownership)

---

## 1. The Problem

Traditional Kubernetes CI/CD splits cleanly into two pipelines with two owners:

- **App CI/CD** (app team): code → image → manifests → deploy to namespace. Fast, independent, small blast radius.
- **Cluster CI/CD** (platform team): provision nodes, install shared services, manage RBAC/policies, upgrade K8s. Slow, coordinated, large blast radius.

The boundary is the **namespace**. The platform team creates it, the app team deploys into it. The contract is implicit: "you get these resources in this namespace."

A compiler that resolves cross-team dependencies, auto-wires infrastructure, and proves correctness at build time **dissolves this boundary**. The compiler's "link phase" — resolving `deps.postgres` into actual wiring — creates a third category that neither pipeline owns in the traditional model. This doc explores how CI/CD should work when the compiler is the integration point.

---

## 2. The NixOS Analogy

NixOS replaced imperative system administration with a single declaration compiled into a consistent system closure. The key shift wasn't "declarative config" — it was that **the entire system is a function of its inputs**, and the compiler guarantees internal consistency.

Before NixOS: the distro provides packages, the user assembles them, conflicts surface at runtime. After: `configuration.nix` compiles to a complete, atomic system generation. Rollback is a pointer swap.

kix does the same for multi-team Kubernetes. But NixOS has two modes that matter here:

1. **System activation** (`nixos-rebuild switch`): one config, one evaluation, atomic switch. Everything is coupled.
2. **Project isolation** (`nix-shell`, `devenv`, flakes): independent closures coexisting on the same machine. They share the nix store (deduplication) but not the activation lifecycle.

kix already has the system activation equivalent — the Activation CR is a content-addressed closure with generation tracking, and rollback is literally "point to the previous activation" (doc 62: activation lifecycle is implemented). The project isolation equivalent exists too — `mkEnv` and separate cluster definitions sharing a base module are working (doc 64 §6).

The design question: **how does this spectrum map to multi-team CI/CD?**

Doc 45 covers the architectural spectrum (monorepo → federated → independent). This doc focuses on the CI/CD implications — who runs what pipeline, when, and how the compilation boundaries map to team autonomy.

---

## 3. The systemPackages Model

The cleanest framing emerged from the NixOS analogy: **app teams publish packages, cluster operators import them** — like `environment.systemPackages` in NixOS.

### How it works

The app team doesn't deploy. They **publish a package**. Their CI:

```
code → build → test → publish package definition
```

Their artifact isn't a container image that gets deployed. It's a versioned module: "here's my service, here are my declared dependencies, here's my interface."

The cluster operator writes:

```nix
# conceptually
services = {
  teamA.api = { version = "1.4.2"; };
  teamB.worker = { version = "2.0.1"; config.replicas = 3; };
  teamC.frontend = { version = "0.9.0"; };
};
```

The operator chooses what to include, at what version, with what overrides. The compiler resolves wiring, dependencies, shared resources, and policies.

### Why this cleanly solves CI/CD ownership

Two completely separate pipelines, no ambiguity:

| Pipeline | Owner | Trigger | Tests | Output |
|---|---|---|---|---|
| **Package CI** | App team | Push to app repo | Unit tests, package compiles in isolation | Published package version |
| **Cluster CI** | Operator | Change to cluster definition | Full compile, diff, policy checks | Applied cluster state |

The boundary is the **package registry**, not the namespace. App teams write to it, operators read from it. The operator can pin versions, compose deliberately, and test combinations before activating.

### Mapping to kix

This maps directly to what kix already has:

- `kix/packages/` = the package library (like nixpkgs)
- `clusters/` = operator-owned cluster definitions (like `configuration.nix`)
- `nix build .#cluster-X` = the compilation step
- The Activation CR = the deployed closure (content-addressed, generation-tracked, rollback-ready)

The multi-repo story is addressed by doc 45 §2b (federated flakes): team flakes as inputs to a cluster flake. The CI/CD implications of that model are the focus of §4 below.

---

## 4. Compilation Granularity

How much gets compiled together, and when? Doc 45 covers the architectural models; this section focuses on their CI/CD characteristics.

### Option 1: One activation per cluster

Every team's inputs → one compilation → one manifest set → atomic apply.

**Strengths:** Maximum cross-team resolution. If two teams both want postgres, the compiler sees both and can deduplicate or split. Correctness is global. This is kix's current model — one `nix build .#cluster-X` per cluster.

**Weaknesses:** Every push from any team triggers a full recompile. Attribution is hard when the compile fails. This is the monorepo trunk-based development problem.

**Works when:** Team count is small OR compilation is very fast (seconds). Maps to doc 45 §2a (monorepo). Nix's caching means unchanged packages are store-path hits — the recompile cost is proportional to what actually changed, not the total cluster size.

### Option 2: Per-team against shared base

Platform team compiles a "base activation" (shared services, policies, budgets). Each team compiles their own activation against that base. The base is a fixed input — like a pinned nixpkgs channel.

**Strengths:** Teams compile and deploy independently. Fast CI per team.

**Weaknesses:** No cross-team resolution. Requires solving the shared resource ownership problem (doc 55) — when multiple activations coexist on a cluster, CRDs, namespaces, and shared infrastructure need reference-counted ownership. Currently an open design problem with several candidate solutions (reference counting via `kix.dev/activations` annotation, infrastructure activations, organizational separation).

**Works when:** Teams are truly independent. Maps to doc 45 §2c (independent activations).

### Option 3: Dependency-scoped compilation

Instead of compiling by team or by cluster, **compile by dependency graph**.

The compiler knows the dependency graph (this is structural — DI resolution in `resolve.nix` and `auto.nix` builds it). Team A depends on postgres and redis. Team B depends on postgres and kafka. Team C depends only on kafka. Connected components: {A, B} share postgres, {B, C} share kafka, so {A, B, C} form one component. Team D, depending on nothing shared, compiles alone.

When Team A pushes, the compiler recompiles only the connected component A belongs to. If A's change doesn't alter the postgres dependency, downstream teams aren't affected — Nix's content-addressing means if the intermediate store path didn't change, dependents don't rebuild (doc 29 §8.1).

**Strengths:** Cross-team resolution where it matters, independence where it doesn't. Compilation unit emerges from dependency structure, not organizational boundaries.

**Weaknesses:** Connected components grow as dependency graphs get dense. Mitigation: treat shared infrastructure as a **stable boundary** (pinned input, like a nixpkgs version).

### Option 4: Transaction model

The compiled cluster state is a persistent artifact — like a database. Each team's change is a transaction. The compiler evaluates: does this maintain all invariants? If yes, commit. If no, reject.

kix already has the primitive for this: the **Activation CR** is a content-addressed, generation-tracked cluster state (doc 62: activation lifecycle is implemented with Queued→Deploying→Active→Superseded). A transaction would compile against the current Active generation, and on success produce a new generation that supersedes it.

**Strengths:** Most git-like model. No batching, no queues, no coordination except on actual conflicts. Rollback is reverting to a previous generation — already implemented.

**Weaknesses:** Conflict resolution for concurrent changes needs design. The Activation CR is currently single-writer.

### Recommendation

Options 3 and 4 are both feasible and complementary. kix's lazy evaluation already enables dependency-scoped compilation. The transaction model maps naturally to the existing Activation lifecycle. The "known-good state" concept already exists — it's the current Active Activation CR.

The CI model becomes: team pushes → compile against current Active generation plus this team's change → if it compiles, produce new Activation → operator deploys it. The "green trunk" discipline is enforced by the compiler.

---

## 5. Shift-Left Self-Service

The purest shift-left model: **the operator doesn't gatekeep individual changes, they gatekeep the policy the compiler enforces**.

```
cluster/
  platform.nix        # operator owns — policies, budgets, base services
  policies.nix         # operator owns — compiler constraints
  teams/
    team-a.nix         # team A owns
    team-b.nix         # team B owns
```

Team A changes `team-a.nix` freely. On push, the compiler evaluates the full cluster definition. If it compiles — change respects all policy constraints, doesn't break other teams' wiring, stays within resource budget — it auto-merges and applies.

If it doesn't compile, the team gets a clear error: "you requested 32Gi memory but your budget is 16Gi" or "postgres 13 is below minimum supported version" or "your ingress rule conflicts with team B's path prefix."

**The operator's role shifts from reviewing individual changes to maintaining the policy modules and the compiler's constraint library.** They write the rules, the compiler enforces them.

kix already has building blocks for this:
- **Scorecard rules** (doc 60, implemented) provide the constraint evaluation framework
- **Capability contracts** (doc 29 §3.5) catch incompatibilities at eval time
- **Structured diagnostics** (doc 80, in progress) surface errors with source attribution
- **`kix check --sarif`** (implemented, doc 64) integrates policy violations into code review

The NixOS equivalent: home-manager compiles within constraints the system config sets. Your compiler's team-scoped compilation is exactly that pattern.

### Self-service spectrum

Start conservative — teams can only bump their package version. Progressively open up as trust in the compiler grows. The compiler's proof system is what makes this safe. Doc 66 milestone M4 targets "the platform team lead" persona with exactly these self-service capabilities.

---

## 6. Dev/Prod as Compilation Parameter

Dev and prod are not separate clusters with separate pipelines. They are **different compilation targets** — like building the same NixOS config with different arguments. This already works in kix.

Doc 64 §6 documents two working patterns:

**Pattern A: Separate cluster definitions sharing a base module** (recommended):
```nix
# clusters/satchel-dev.nix
{ imports = [ ./satchel-base.nix pkgs.lib.flavors.gke ]; }
# clusters/satchel-prod.nix — same packages, different config
{ imports = [ ./satchel-base.nix pkgs.lib.flavors.gke ]; }
```

**Pattern B: `mkEnv` for shared-cluster environments** — stamps namespaces when dev and prod share a physical cluster.

The compiler proves wiring correctness in both. The difference is only at the leaves (replica counts, storage backends, resource limits), not in the dependency structure.

### Fluid boundaries

The traditional dev/staging/prod split is unnecessarily rigid:

- **Experimentation sandbox**: isolated, compile-alone, can't affect anyone. The `nix-shell` equivalent.
- **Dev**: may compile against real shared components to prove integration, but with dev-only stateful resources.
- **Staging**: compiles with the same components as prod. The point is proving the wiring, not running a separate copy.
- **Prod**: full compilation with production parameters.

Dev doesn't need cross-team compilation. Prod is the system activation. That split may be the right default: **dev compiles in isolation (fast, independent), prod compiles in context (cross-team, policy-enforced).**

---

## 7. kix Subsumes Flux, Not Complements It

Doc 88b has detailed feature-by-feature mapping and an explicit migration path ending with `flux uninstall`. The key framing:

**Flux doesn't understand what it's applying.** It watches git, renders templates at runtime, and applies manifests. If there's a bug in the YAML, Flux faithfully applies it. Cross-team coherence doesn't exist — each HelmRelease/Kustomization is independent.

**kix understands everything.** It resolves dependencies at eval time, derives ordering from the DAG (not manual `dependsOn`), validates cross-resource references, and produces correct manifests by construction.

| Concern | kix | Flux |
|---|---|---|
| Cross-team coherence | Compiler resolves at build time | None — each HelmRelease is independent |
| Policy enforcement | By construction (compile-time) | Gatekeeper/Kyverno (apply-time, reactive) |
| Drift detection | Content-hash comparison (exact) | Periodic reconciliation (label-based) |
| Resource ordering | DAG-derived waves (automatic) | `dependsOn` annotations (manual) |
| Pruning/GC | Content-addressed ownership (structural) | Label matching (fragile on rename) |
| Stateful transitions | Migration pairs with strategy selection (doc 67) | None — Flux has no concept of data movement |

kix's operator (doc 62) is the delivery mechanism — it replaces Flux's reconciliation loop, not complements it. The operator engine is functionally complete (reconcile, drift detection, activation lifecycle, finalizer-based GC). Remaining work is production hardening: OCI transport, container image, leader election, metrics (doc 62 phases 1-3).

For adoption, kix can coexist with Flux during migration via distinct SSA field managers (doc 88b §"Incremental migration"). But the architecture is designed to subsume Flux entirely, not sit alongside it permanently.

---

## 8. State Transitions: The Compiler's Unique Advantage

Unlike NixOS, kix does NOT punt on state. This is one of its strongest differentiators.

NixOS compiles the system closure but leaves state transitions (database upgrades, data migrations) to the user. kix's closure diff carries enough semantic context to detect, plan, and orchestrate stateful migrations — because the compiler sees the **entire cluster definition** including dependencies, storage, hardware profile, and lifecycle metadata.

### How it works (doc 67)

When the closure diff produces a removed resource and an added resource in the same package instance and dependency slot, they form a **migration pair** — a structural fact (not a heuristic) that data needs to move:

```
MigrationPair {
  source: PVC (local-path, 100Gi)
  target: PVC (zpool-fast, 200Gi)
  consumer: immich
  reason: "storageClass changed: local-path -> zpool-fast"
  riskLevel: high
}
```

The compiler knows (1) what changed, (2) why it changed (traceable through hardware profile → storage config → PVC), (3) what depends on it, and (4) whether it's stateful. No GitOps tool, no operator, no runbook has all four pieces of information at once.

### Strategy selection and execution

Each migration pair gets an automated strategy: resize (if same provisioner, size-only change), copy-local (rsync), pg_dump/pg_restore (database version upgrade), or manual (flagged for human intervention). Packages declare migration hints — `maxVersionJump = 1` for postgres prevents invalid 15→17 upgrades at compile time.

### Integration with the lifecycle engine (doc 81)

Doc 81 reframes deploy as a kind-aware lifecycle engine with typed `Transition` primitives: `Apply`, `Recreate`, `Migrate`, `Drain`, `Delete`, `Pause`. Migrations aren't a separate phase — they're first-class transitions in the same plan the user reviews before anything executes. The plan shows exactly what will happen:

```
Plan for ludo@gen5:
  87 unchanged
   3 apply      (Deployment/n8n, ConfigMap/n8n-config, Service/n8n)
   2 migrate    immich/storage: local-path → zfs-tank (rsync, ~45m, HIGH)
                postgres/data:  local-path → zfs-tank (pg_dump, CRITICAL)
   1 pause      StatefulSet/postgres (gating: requires approval)
```

### CI/CD implication

The CI/CD model must distinguish between two categories of cluster changes:

- **Compile-verified, stateless changes** — safe to auto-apply. Image bumps, config changes, adding stateless services.
- **State-transitioning changes** — require the migration plan, user confirmation (or policy-based auto-approval), and the lifecycle engine's orchestration.

The compiler detects which category a change falls into. CI can auto-deploy the first and gate the second. This is a qualitative advantage over traditional CI/CD where every change gets the same deploy treatment regardless of risk.

---

## 9. Scaling Concerns

### Dependency graph density

At 5 teams: 3 independent compilation components. At 50 teams: possibly one giant component because everyone depends on postgres/redis/kafka. Mitigation: treat shared infrastructure as **stable boundaries** — pinned inputs, not co-compiled. The platform team upgrades shared services on a separate cadence. Nix's content-addressing makes this natural: if the shared postgres package didn't change, its store path is a cache hit and dependents don't rebuild.

### Conflict combinatorics

Team A needs postgres with PostGIS. Team B needs TimescaleDB. Team C needs both. At 50 teams, the conflict matrix is unmanageable for humans. This is actually a **strong argument for the compiler** — the DI resolver already handles multi-instance disambiguation. But error messages must be actionable. Structured diagnostics (doc 80, in progress) address this with source-attributed errors.

### Governance and shared resource ownership

Who can change shared inputs? When multiple activations share a cluster, CRDs, namespaces, and shared infrastructure need careful ownership semantics. Doc 55 explores this actively: reference-counted ownership via `kix.dev/activations` annotation (already tracks which activations reference each resource), infrastructure activations as a separate lifecycle, and organizational separation. This is an open design problem whose resolution directly affects the multi-team CI/CD model.

### Speed

Compilation speed is a feature. Nix's lazy evaluation means only changed packages and their dependents re-evaluate. The Merkle DAG provides exact change propagation — not "might be affected" but "cryptographically proven affected" (doc 29 §8.1). For CI, `kix diff` already supports snapshot-based offline diffing (doc 64 §2) so PR checks don't need cluster credentials.

### The commons problem

The compiled cluster state is a shared artifact. The failure mode: Team A's hotfix is blocked because Team B's experimental change broke the compile. The Activation CR's generation model provides the primitive — compile against the current Active generation, not against uncommitted changes from other teams. Changes land in `main` only after passing compilation. This is trunk-based development, enforced by the compiler.

---

## 10. Who Benefits Most

| Segment | Why | Compiler leverage |
|---|---|---|
| **5-30 team orgs with shared infra** | Coordination cost is the pain point | Converts coordination from human process to mechanical one |
| **Regulated industries** (fintech, healthcare) | Compliance is expensive and reactive | Policy by construction, not by policing. `kix check --sarif` provides machine-readable compliance evidence |
| **High microservice count + shared stateful deps** | Configuration drift across 50 postgres setups | Compiler enforces consistency; divergence requires intentional override |
| **Multi-tenant SaaS** | Same stack, many customers/regions | Parameterized compilation: same packages, different inputs per cluster |

**Not enough benefit:**
- Single-team startups (no coordination problem — though even here, kix eliminates wiring errors)
- Fully independent services (nothing to co-resolve)

These map to doc 66's milestone users: M1 = Sam (startup CTO), M4 = platform team lead (self-service), M5 = IDP buyer (full catalog + multi-team).

---

## 11. Design Implications for kix

1. **The package/operator separation already exists** (`packages/` and `clusters/`). The CI/CD model should reinforce it: package CI is per-package, cluster CI is per-cluster-definition. Doc 64 §2 (GitHub Action for diff-as-PR-comment) is the near-term vehicle.

2. **Dependency-scoped compilation aligns with nix lazy eval.** The DI graph is already computed at eval time — surfacing connected components for CI scoping is a natural extension of what `resolve.nix` already does.

3. **The Activation CR is the "known-good state" primitive.** For multi-team workflows, "compile against current Active generation" provides the transaction semantics from §4. No new concept needed — extend the existing lifecycle.

4. **Self-service requires the scorecard + diagnostics pipeline.** The building blocks exist (scorecard rules, SARIF export, structured diagnostics). The gap is policy primitives for per-team budgets and constraints — these are module system options, not new infrastructure.

5. **State transitions are a CI/CD concern, not a separate problem.** The lifecycle engine (doc 81) integrates migration into the deploy plan. CI should surface migration risk classification — auto-deploy stateless changes, gate stateful ones — using the same `Transition` types the engine uses.

6. **Shared resource ownership (doc 55) is the blocker for multi-activation CI/CD.** Until ownership semantics are resolved, the practical model is one activation per cluster (option 1 from §4). The other options require reference-counted ownership or infrastructure activation separation.

---

## 12. Open Questions

1. **Package registry semantics.** In the systemPackages model, what does "publishing a package" mean concretely? A flake input? An OCI artifact? A git tag in a separate repo? The registry is the contract boundary — its design matters. Doc 45 §2b (federated flakes) is the nearest existing answer.

2. **Connected component computation for CI.** Can the compiler efficiently surface which teams are in the same dependency component? What's the API for CI to query "which teams are affected by this change"? This is derivable from the DI graph but not yet exposed.

3. **Auto-promotion policies.** In the self-service model, which changes auto-merge and which require operator review? The lifecycle engine's `Transition` types provide a natural classification: `Apply` transitions can auto-promote, `Migrate` and `Pause` transitions require review.

4. **Cross-team diff visibility.** When Team A's change alters Team B's compiled output, how is Team B notified? The Merkle DAG provides exact blast radius computation (doc 29 §8.2) — the question is the notification mechanism (PR comment, CI job, dashboard).

5. **Multi-activation ownership resolution.** The multi-team CI/CD models (options 2-4 in §4) all depend on solving shared resource ownership (doc 55). Which solution path — reference counting, infrastructure activations, organizational separation — best serves the CI/CD workflow?
