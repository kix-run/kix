# 106: kix ops surface — lifecycle verbs and build-time capacity check

**Status:** Brainstorm / RFC
**Relevance:** Active
**Related:** `105_ludo_homelab_operational_readiness.md`, `62_operator_production_implementation_plan.md`, `67_stateful_migration_orchestration.md`, `80_structured_diagnostics.md`, `cli/README.md`, `kix/lib/architecture.md`

## Why this doc

Doc 105 surfaced two cross-cutting kix gaps that are *not* about per-package intents and *not* about the homelab operator's checklist:

- **kix has `deploy`. It doesn't have lifecycle verbs.** `bootstrap`, `restore`, `upgrade`, `drift` are runbooks today; they should be commands.
- **kix knows every workload's resource requests at compile time and knows the cluster's hardware profile, but doesn't compute whether they fit.** Single-node clusters silently overcommit.

Both are small (relative to the intent / capability work in doc 105) and rest entirely on machinery that already exists: the Activation closure rooted by `mkActivation`, the cluster-level eval in `eval/cluster.nix`, structured diagnostics (doc 80), the existing kind-rehearsal clusters in `ludo/cluster-kind-upgrade-*.nix`. They are missing *surfaces*, not missing *eval*.

This doc captures them so doc 105 can stay focused on the operator-checklist view.

## Architectural framing

Per `kix/lib/architecture.md`:

- `mkActivation` roots the deploy closure. The CLI walks `nix-store -q --tree` on the Activation derivation to obtain the full deploy DAG. Every verb below reuses this — they are different *consumers* of the same eval, not new eval modes.
- `cluster.hardware` is already a real schema (shipped, see archived `45_cluster_hardware_profile.md`). Capacity check is one new pure function that reads it.
- Structured diagnostics (doc 80) is the warning channel for both upgrade-time API removals and capacity over-subscription.
- Scorecard rules in `rules/` are data-only extensions; capacity over-subscription becomes a rule with cluster-level scope.

Nothing below requires rearchitecting `eval/`. The work is wiring + new files in well-understood slots.

## Part 1 — Lifecycle verbs

### 1.1 `kix bootstrap`

**Intent:** zero-to-running on a fresh node, from a checked-out cluster definition + a SOPS key.

**Decomposition:**

1. **Pre-flight** — pure eval, no cluster contact.
   - Walk all referenced secrets in the cluster definition.
   - Verify each can be decrypted by *this operator's* key (not just that the file is well-formed).
   - Verify every `meta.stateful` instance has a backup-engine DI dep resolved.
   - Verify every `meta.exposure` has an enforcer instance available.
   - Output: structured diagnostics report (doc 80 shape). Fatal items block.

2. **Apply** — delegate to existing `kix deploy`. No new code path.

3. **Smoke** — post-Activation health walk.
   - New convention: capability roots may expose `out.healthcheck` — a runtime probe expressed as a Kubernetes probe spec (HTTP / exec / tcp). Not a new resource, just a structured value attached to the root.
   - CLI iterates capability roots in dependency order, executes probe via `kubectl`. Block on green.

**New artefacts:**
- `kix/lib/eval/preflight.nix` — pure pre-flight check, returns structured diagnostics. Composable: callable from CI as well.
- `out.healthcheck` convention. Documented in `architecture.md` alongside `out.name`/`out.fqdn`/etc.
- CLI: `kix bootstrap` subcommand, ~thin orchestrator over the three phases.

**Not in scope:**
- Bootstrapping the *node* (k3s install, OS prep). That's the operator's runbook.
- Bootstrapping the SOPS key itself (chicken-and-egg; operator brings it).

### 1.2 `kix restore`

**Intent:** drive a stateful workload back to a known-good past state.

**Architectural fit:** the backup engine package (per data class — see doc 105 §A2 "backup is a typed DI capability") declares not just *how to back up* but *how to restore*:

- `engine.out.restore` — a function `(target :: instance, point :: timestamp) → restore manifest set`. Engine-specific: CNPG emits a `Cluster` with `bootstrap.recovery`; restic emits a `Job` that mounts a fresh PVC and `restic restore`s into it; etcd emits an `etcd-snapshot-restore` Job.

**Verb behaviour:**

```
kix restore --workload pg-main --to '2026-04-25T03:00Z'
```

1. Eval cluster.
2. Find instance `pg-main`. Resolve its backup engine.
3. Build `engine.out.restore { target = instance; point = ts; }` as a *separate Activation* (so the restore plan is itself observable: `nix-store -q --tree` on it gives the restore DAG).
4. Apply.

**Why a separate Activation:** restore is a one-shot transaction with a different lifetime than the cluster's steady state. Treating it as just-another-deploy would conflate "this is the cluster's desired state" with "I'm temporarily applying a recovery plan". Restore Activations are siblings of deploy Activations and are visible in `kix history`.

**New artefacts:**
- `out.restore` convention on backup engine roots.
- A new `_type` recognized by `mkActivation` for restore-class activations (so they're tagged distinctly in the activation history — see §1.4 below).
- CLI: `kix restore <workload> [--to <ts>]`.

**Open question:** does restore need to coordinate quiesce of dependents? E.g. restoring `pg-main` should pause the apps that talk to it. This overlaps with doc 67 (stateful migration orchestration) — restore is a *shape* of stateful migration. May want to defer the dependent-quiesce design to 67 and ship `kix restore` initially as "apply the engine's restore plan; the operator handles dependents".

### 1.3 `kix upgrade --target k3s=v1.31`

**Intent:** rehearse a k3s (or downstream-distro) version bump in kind, surface breaking diffs, then apply.

**Architectural fit:** half-built already.
- Flavors in `kix/lib/flavors/k3s.nix` etc. — parameterize the version explicitly.
- `ludo/cluster-kind-upgrade-broad.nix` and `cluster-kind-upgrade-small.nix` are exactly the kind-rehearsal cluster definitions this verb wraps.
- `scripts/kix-diff.py` is the resource diff engine.
- Scorecard rules can express "API removed in target version" as a data-only addition.

**Verb behaviour:**

```
kix upgrade --target k3s=v1.31 [--apply]
```

1. Eval cluster with current flavor version → resource set A.
2. Eval cluster with `flavors.k3s { version = "v1.31"; }` → resource set B.
3. Diff A and B. Surface differences (mostly empty for pure version bumps, but CRD bundle / addon manifests change).
4. Run scorecard against B with rule `architecture.removedApis` enabled (data-only rule keyed on Kubernetes API deprecations). Fail on any matched usage.
5. Spin up a kind cluster at the target version (existing `cluster-kind-upgrade-*.nix` machinery), apply B, run smoke probes (§1.1 step 3 reused).
6. If `--apply` and steps 1–5 are green: snapshot the live node's etcd + ZFS dataset, apply B to live, monitor.

**New artefacts:**
- Parameterize `flavors/k3s.nix` (and peers) with explicit `version`.
- `kix.evalAt { flavor; version; }` — a small helper exposing "eval the same cluster against a different flavor instantiation".
- `architecture.removedApis` scorecard rule. Data is a static table of "API X removed in version Y" updated as part of release tracking.
- CLI: `kix upgrade --target <kv pair>` with `--apply` gate.

**Open questions:**
- How does upgrade interact with stateful migrations on the same window? doc 67's primitives subsume `kix upgrade` — formally, `kix upgrade` is a `Plan/Transition/Verdict` flow per doc 81 (deploy as lifecycle engine). May want to hold this verb until 81's transition primitives are concrete, so `kix upgrade` is implemented *on top of* them rather than parallel to them.
- Rollback: snapshotting before apply is operator-side. Should the verb own snapshot creation, or just refuse to proceed without one?

### 1.4 `kix drift`

**Intent:** detect when the live cluster diverges from the eval'd desired state, alert the operator.

**Architectural fit:** `scripts/kix-dump.py` + `scripts/kix-diff.py` already exist. The verb is "promote them and run on a schedule".

**Two surfaces:**

- **One-shot CLI:** `kix drift` from the laptop. Re-evals locally, dumps live cluster, diffs, prints structured diagnostics.
- **Scheduled in-cluster:** new `kix/lib/modules/drift.nix` renders a `CronJob` (single-node era) that runs `kix-dump` + `kix-diff` against itself and routes output through Alertmanager → ntfy. Long term, the activation operator (doc 62) absorbs this — it already evaluates and reconciles, so drift detection is one new code path inside it.

**New artefacts:**
- Promote `kix-dump`/`kix-diff` from `scripts/` to a CLI command pair (the python prototypes can stay; the CLI shells out or reimplements).
- `modules/drift.nix` — schedule + alert routing.
- CLI: `kix drift [--live <kubeconfig>]`.

**Activation history connection:** drift output is most useful when correlated with the last activation. `kix drift` should print "live diverges from desired; last applied activation was `<id>` at `<ts>`". This requires §1.5.

### 1.5 Activation history (cross-cutting prerequisite)

**Intent:** answer "what changed when" without grepping git.

`mkActivation` already roots the closure and stamps identity. What's missing is the *queryable surface*:

- Every applied Activation gets a row in a small store (a CRD, `ActivationLog`, or a flat-file inside the cluster definition repo, or both).
- Row contains: activation ID (root hash), apply timestamp, operator (kubeconfig user), target cluster, diff summary, kind (`deploy` | `restore` | `upgrade`).
- New CLI verb: `kix history [--workload foo] [--since 1h]` — filtered query.

**Why now:** every other lifecycle verb wants this. `kix bootstrap` wants to know if there's already a recent Activation. `kix restore` wants to record itself distinctly from `deploy`. `kix drift` wants to correlate divergence with last apply. `kix upgrade` wants to record the version delta.

**New artefacts:**
- `ActivationLog` CRD or equivalent. CRD is preferable because it lives where the cluster lives and the kix activation operator can write it natively (doc 62).
- Distinct Activation `kind` field on `mkActivation`.
- CLI: `kix history`.

## Part 2 — Build-time capacity check

### 2.1 Why this is small

By the time `eval/cluster.nix` finishes the fixpoint, every workload's `resources.requests` is a known value. `cluster.hardware.allocatable` is a known value. The check is one pure summation + comparison + a structured-diagnostic emission.

The reason it doesn't exist yet is that *nobody asked for it*; the framing for `cluster.hardware` was scheduling/affinity, not capacity validation.

### 2.2 Shape

**One new file:** `kix/lib/eval/capacity.nix`. One pure function:

```nix
computeNodeFit = { hardware, instances }:
  let
    perWorkload = collectWorkloads instances; # cpu/memory requests per workload
    total = sumRequests perWorkload;
    allocatable = hardware.allocatable; # already in cluster.hardware schema
    reserved = hardware.systemReserved or { cpu = 0; memory = 0; };
    available = subtractResources allocatable reserved;
  in {
    inherit total available;
    oversubscribed = exceedsAny total available;
    perWorkload; # for diagnostic detail
  };
```

**Wiring:** called from `eval/cluster.nix` post-fixpoint, alongside `processInstance` (the existing post-fixpoint extension hook used by netpol's supplementary-CNP pass).

**Output:** a structured diagnostic per doc 80. Severity controlled by the new scorecard rule below.

### 2.3 Scorecard rule

**New rule:** `reliability.capacityOversubscribed` at level `cluster`. Data-only addition to `kix/lib/rules/`.

```nix
capacityOversubscribed = {
  level = "cluster";
  defaultSeverity = "warn";
  check = { eval, ... }:
    let fit = capacity.computeNodeFit { /* ... */ };
    in if fit.oversubscribed
       then fail "total requests exceed available: ${fmt fit}"
       else ok;
};
```

Severity uses the existing scorecard precedence chain. The "homelab production" flavor (doc 105) overrides this to `error`; lab clusters keep `warn`.

### 2.4 Schema additions

Extend `cluster.hardware` in `kix/lib/modules.nix`:

- `singleNode :: bool` (default `false`).
- `systemReserved :: { cpu :: ResourceQty; memory :: ResourceQty; }`. Single-node default: 10% of allocatable. Multi-node default: 0 (kubelet handles it).

### 2.5 Single-node-aware module

A small companion module `kix/lib/modules/single-node.nix` that activates when `cluster.hardware.singleNode = true`:

- Sets `systemReserved` to 10% of allocatable if not explicitly set.
- Promotes `capacityOversubscribed` to `error` (via scorecard severity override).
- Strips synthesized `PodDisruptionBudget`s (meaningless on single node).
- Reduces synthesized pod anti-affinity from `required` → `preferred` (or strips entirely; open question).
- Promotes `architecture.statefulNeedsBackup` to `error` (data loss on single node has no recovery path other than backup).

The module is a *post-processing pass* over the fixpoint output, same shape as the existing post-fixpoint passes. Strict opt-in via `cluster.hardware.singleNode`.

### 2.6 What this is *not*

- Not scheduling. The kube-scheduler still does scheduling; this check just refuses to ship a manifest set that *cannot* be scheduled.
- Not autoscaling. Single-node has no autoscaling story; multi-node autoscaling is a separate doc.
- Not pod-level. The check is *aggregate cluster fit*, not per-pod admission. Per-pod admission is the kubelet's job at runtime.

## Roadmap

Sequenced for minimum cost-to-value and to respect the "build on existing primitives" constraint.

### Phase A (smallest, highest leverage — 1–2 weeks of work)
1. **Capacity check** (Part 2). One file, one rule, schema delta. Slots into existing post-fixpoint pass.
2. **`single-node` module** (Part 2.5). Activates the capacity check at error level, strips PDB/anti-affinity, raises stateful-needs-backup.
3. **`kix drift` one-shot** (§1.4). Promote scripts to CLI command. No scheduling yet.

### Phase B (depends on doc 105 backup engine work — 2–4 weeks)
4. **Activation history CRD + `kix history`** (§1.5). Cross-cutting, unblocks the rest.
5. **`kix bootstrap`** (§1.1). Pre-flight + smoke. The pre-flight is reusable in CI.
6. **`out.healthcheck` convention** + capability roots adopting it (§1.1 step 3).

### Phase C (depends on doc 67 + doc 81 maturation)
7. **`kix restore`** (§1.2). Hold until backup engine convention from doc 105 lands.
8. **`kix upgrade`** (§1.3). Hold until doc 81 transition primitives are concrete; implement on top of them rather than parallel.
9. **`kix drift` scheduled mode** + activation operator integration. Hold for doc 62 progress.

## Open questions

1. **Activation log location.** CRD vs flat-file vs both. CRD is more "kubernetes-native" but the data is also valuable when the cluster is *gone* (post-mortem). Probably both, with the CRD authoritative when the cluster is reachable.
2. **Should `kix bootstrap` be additive on top of `kix deploy`** (i.e. you can call `deploy` standalone and skip pre-flight), or should pre-flight always run? Leaning "always run, but allow `--skip-preflight` for the rare case where you need to deploy a fix before pre-flight passes". Scorecard severity precedence is the right model.
3. **Capacity check granularity for multi-node.** Per-node fit (does any individual node fit the largest pod) vs aggregate fit (does the sum fit the cluster). Single-node makes them identical; multi-node needs both.
4. **Restore dependent-quiesce.** Coordinate with doc 67 — probably restore stays simple ("apply engine's plan") and doc 67 owns the orchestration around it.
5. **Upgrade rollback ownership.** Should `kix upgrade --apply` create the rollback snapshot itself, or refuse to run without one? Operator-side simplicity argues for the former; auditability argues for the latter.

## What this doc is *not*

- Not a backup design. See doc 105 §A2 + the corrected layering ("backup is a typed DI capability, not an intent").
- Not an operator (doc 62) replacement. The operator is the long-term host of `drift` and `history`; this doc just specifies the surfaces.
- Not a doc 81 substitute. `kix upgrade` is *one* concrete consumer of doc 81's transition primitives; doc 81 is the underlying engine.
