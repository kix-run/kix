# Activation-Centric GitOps Operator

**Status:** Design RFC
**Related:** `28_gitops_deploy.md` (feature parity), `10_merkle_dag_package_instance.md` (PackageInstance/DAG), MAJOR_FEATURES.md (content-addressing use-cases), ROADMAP.md (operator section)

---

## 1. Core Idea

The kix operator has exactly one primitive: **Activation**.

```
Activation created  → deploy its closure
Activation updated  → reconcile (diff old hash vs new hash, apply delta)
Activation deleted  → GC (remove resources unique to this activation)
```

The operator never reasons about individual resources, packages, namespaces, or diffs-against-live-state as top-level concerns. It only watches Activation CRs. Everything else — what to deploy, what changed, what to delete — is derived from comparing Nix store closures.

This is a fundamentally different model from ArgoCD/Flux, which reconcile "desired YAML vs live YAML." The kix operator reconciles "activation hash A vs activation hash B" — two known-good snapshots, not one snapshot against mutable cluster state.

---

## 2. The Activation CR

### On-cluster representation

```yaml
apiVersion: kix.dev/v1alpha1
kind: Activation
metadata:
  name: production
  annotations:
    kix.dev/previous-hash: /nix/store/xyz789...-activation-production
    kix.dev/generation: "42"
    kix.dev/source-commit: "abc1234"
spec:
  # How the operator obtains the evaluated closure
  source:
    # Option A: push-based — CI evaluates, operator deploys
    type: storePath
    path: /nix/store/abc123...-activation-production

    # Option B: pull-based — operator evaluates from git
    # type: git
    # repo: https://github.com/org/infra.git
    # ref: main
    # flakeAttr: cluster-production

  # Operator behavior knobs
  policy:
    driftRemediation: auto  # auto | alert | disabled
    failureStrategy: halt   # halt | rollback | continue
    pruneStateful: prompt    # auto | prompt | disabled
    reconcileInterval: 5m

  instances:
    default:
      postgres: kix-PackageInstance-default-postgres-<hash>
      app: kix-PackageInstance-default-app-<hash>
    monitoring:
      prometheus: kix-PackageInstance-monitoring-prometheus-<hash>

status:
  phase: Healthy  # Deploying | Healthy | Degraded | RollingBack | GarbageCollecting
  currentHash: /nix/store/abc123...-activation-production
  previousHash: /nix/store/xyz789...-activation-production
  lastReconciled: "2026-03-27T14:30:00Z"
  resourceCounts:
    total: 47
    unchanged: 42
    applied: 3
    pruned: 2
  waves:
    - wave: 0
      status: Complete
      resources: ["Namespace/monitoring", "Namespace/default"]
    - wave: 1
      status: Complete
      resources: ["ServiceAccount/prometheus", "ConfigMap/prometheus-config"]
    - wave: 2
      status: InProgress
      resources: ["Deployment/prometheus"]
  drift:
    detected: 1
    resources: ["ConfigMap/app-config"]
```

### What already exists in kix

`mkActivation` in `lib/k8s.nix` already produces this resource. `buildCluster` in `lib/eval/cluster.nix` already creates one per cluster, listing all active PackageInstances. The store DAG is already fully traceable via `nix-store --tree` on the activation's store path.

What's new is making the Activation the **sole interface** between evaluation and deployment — and building an operator control loop around it.

---

## 3. The Control Loop

```
┌──────────────────────────────────────────────────────────────┐
│                     Activation Controller                     │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  WATCH: Activation CRs via K8s informer                       │
│                                                               │
│  On CREATE or UPDATE (spec.source changed):                   │
│                                                               │
│    ┌─ 1. RESOLVE ─────────────────────────────────────────┐   │
│    │  Obtain the new closure:                              │   │
│    │  - storePath: use directly                            │   │
│    │  - git: nix build .#<attr> → store path               │   │
│    │  Parse packageIndex.json from closure                  │   │
│    └───────────────────────────────────────────────────────┘   │
│                          ↓                                    │
│    ┌─ 2. DIFF ────────────────────────────────────────────┐   │
│    │  old = status.currentHash closure (set of store paths)│   │
│    │  new = resolved closure (set of store paths)          │   │
│    │                                                       │   │
│    │  unchanged = old ∩ new   (same hash → skip)           │   │
│    │  added     = new \ old   (new resources)              │   │
│    │  removed   = old \ new   (resources to GC)            │   │
│    │  changed   = identity-hash match, content-hash differs│   │
│    │                                                       │   │
│    │  This is O(set-diff on hashes), not O(n × YAML-diff). │   │
│    │  The operator never fetches live state to decide       │   │
│    │  what changed — it compares two known-good closures.  │   │
│    └───────────────────────────────────────────────────────┘   │
│                          ↓                                    │
│    ┌─ 3. PLAN ────────────────────────────────────────────┐   │
│    │  Build DAG from depends-on annotations                │   │
│    │  Kahn's algorithm → wave assignment                   │   │
│    │  Filter waves to only (added ∪ changed) resources     │   │
│    │  Compute GC plan: removed, in reverse wave order      │   │
│    └───────────────────────────────────────────────────────┘   │
│                          ↓                                    │
│    ┌─ 4. APPLY (wave-by-wave) ────────────────────────────┐   │
│    │  for wave in waves:                                   │   │
│    │    SSA-apply all (added ∪ changed) resources in wave  │   │
│    │    Wait for readiness (per-kind health checks)        │   │
│    │    Update status.waves[n]                             │   │
│    │    On failure → halt | rollback | continue per policy │   │
│    └───────────────────────────────────────────────────────┘   │
│                          ↓                                    │
│    ┌─ 5. PRUNE ───────────────────────────────────────────┐   │
│    │  Delete resources in `removed` set                    │   │
│    │  Reverse wave order (dependents before dependencies)  │   │
│    │  Stateful resources: obey pruneStateful policy        │   │
│    └───────────────────────────────────────────────────────┘   │
│                          ↓                                    │
│    ┌─ 6. FINALIZE ────────────────────────────────────────┐   │
│    │  status.currentHash = new hash                        │   │
│    │  status.previousHash = old hash                       │   │
│    │  status.phase = Healthy                               │   │
│    │  Persist (timestamp, hash, commit) to history         │   │
│    └───────────────────────────────────────────────────────┘   │
│                                                               │
│  On DELETE:                                                   │
│    unique = closure(this activation) \ closure(all others)    │
│    Delete unique resources in reverse wave order              │
│    Remove finalizer                                           │
│                                                               │
│  PERIODIC (drift detection):                                  │
│    For each resource in current closure:                       │
│      Compare live content-hash annotation vs expected          │
│      Mismatch → auto-remediate | alert per policy             │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### Resumability

The operator persists wave progress in `status.waves`. If it crashes mid-deploy, it resumes from the last incomplete wave. Unchanged resources (same hash) in completed waves are skipped instantly on retry — no re-verification needed.

### Rollback

Rollback = update the Activation's spec to point to `status.previousHash`. The operator runs the normal DIFF → PLAN → APPLY → PRUNE cycle, but now "new" is the old hash and "old" is the current hash. Resources that were added get pruned; resources that were removed get re-created. The closure is likely still in the nix store cache — if not, it's deterministically rebuildable from the source commit.

---

## 4. What This Enables That No GitOps Tool Can Do

### 4.1 Parallel activations — shared resources via content-addressing

Two activations can coexist on the same cluster:

```yaml
- name: production
  # hash: /nix/store/aaa...
- name: canary-v2
  # hash: /nix/store/bbb...
```

Resources with identical content-hashes are **the same store path**. The operator recognizes this: if `production` and `canary-v2` both include a ConfigMap with hash `xyz`, it's deployed once and owned by both. The canary activation only deploys resources whose hashes differ from production.

**Resource ownership** uses reference counting:

```yaml
annotations:
  kix.dev/activation-refs: "production,canary-v2"  # who needs this resource
```

A resource is pruned only when its last activation reference is removed.

This makes the following scenarios trivial:

#### Zero-cost canary deployments

A canary is a second activation pointing to a different evaluation of the same cluster definition (e.g., with one package version bumped). 95% of resources have identical hashes — they're shared, not duplicated. The canary only materializes the changed service + its transitive dependents (new hashes).

No other GitOps tool can do this. ArgoCD would deploy a full copy of the environment. Flux has no concept of shared resources across applications.

#### PR preview environments

A PR activation shares all unchanged infrastructure with production. Only the modified packages get their own resources. Create the activation on PR open, delete on merge/close — GC handles the rest.

```yaml
- name: production
- name: pr-142
  source:
    type: git
    ref: refs/pull/142/head
    flakeAttr: cluster-production
```

The PR environment is not a "copy" — it's a divergent branch of the same content-addressed graph. Shared databases, shared ingress controllers, shared monitoring — only what the PR changed is different.

#### Blue-green as two activations

Blue and green are two activations. "Switch" means updating which one is marked active (traffic routing). "Cleanup" means deleting the old activation — GC removes its unique resources, keeps shared ones.

#### Multi-tenant isolation with shared infrastructure

Different teams get different activations that share common infrastructure (ingress, monitoring, cert-manager) but have isolated application stacks. Infrastructure changes propagate to all activations (same hash), application changes are scoped.

### 4.2 Closure-diff deploys — never compare against live state

ArgoCD's core operation is: "fetch live state, diff against desired state, apply delta." This is expensive (fetch all resources), fragile (server-side mutations make live state diverge from what was applied), and slow (deep YAML comparison).

The kix operator's core operation is: "diff closure A against closure B." Both are known, immutable, locally available Nix store paths. The diff is a set operation on hashes — O(n) hash comparisons, no network calls, no YAML parsing.

Live state is only consulted for:
1. Health checks (is the Deployment actually running?)
2. Drift detection (periodic, not on every reconcile)

This means reconciliation after a `git push` is **faster than any existing tool** — the operator already knows exactly which resources changed before it touches the API server.

### 4.3 Activation lineage — auditable history as a DAG

Each activation records its predecessor:

```
production@gen42 ← production@gen41 ← production@gen40 ← ...
```

Since each generation is a Nix store path (deterministic, content-addressed), you can:

- **Diff any two generations**: what changed between gen38 and gen42? Set-diff the closures.
- **Bisect failures**: binary search through activation generations to find which hash introduced a regression — without re-deploying, just by inspecting closures.
- **Audit trail**: the full history of what was deployed when, as a chain of immutable hashes linked to git commits.

This is `git log` for your cluster state — except every "commit" is a complete, verifiable, reproducible snapshot.

### 4.4 Activation-scoped garbage collection

When an activation is deleted:

```
to_remove = closure(deleted_activation) \ union(closure(a) for a in remaining_activations)
```

Resources shared with other activations survive. Resources unique to the deleted activation are removed. No label-selector heuristics, no "prune" annotation, no orphan detection heuristics. **GC is a set operation on content hashes.**

This means:
- Decommissioning a preview environment is `kubectl delete activation pr-142` — done
- Decommissioning a canary is `kubectl delete activation canary-v2` — shared resources stay
- Decommissioning an entire cluster is deleting its last activation — full cleanup

### 4.5 Speculative activation — dry-run as a real object

Create an activation with `spec.dryRun: true`:

```yaml
- name: production-next
  source:
    type: storePath
    path: /nix/store/new-hash...
  policy:
    dryRun: true
```

The operator runs RESOLVE → DIFF → PLAN but stops before APPLY. The plan is written to `status`:

```yaml
status:
  phase: DryRun
  plan:
    apply: 3
    prune: 1
    unchanged: 43
    waves: [...]
    riskAssessment:
      statefulChanges: ["StatefulSet/postgres"]
      newNamespaces: []
      deletedResources: ["ConfigMap/old-config"]
```

This is "what would happen if I deployed this" as a first-class Kubernetes object — watchable, diff-able, and automatable. CI can create a dry-run activation on every commit and block merge if `statefulChanges` is non-empty.

### 4.6 Activation constraints — declarative deploy policies

```yaml
spec:
  constraints:
    requireApproval:
      - statefulChanges
      - namespaceDeletes
    syncWindows:
      - cron: "0 9-17 * * MON-FRI"  # only during business hours
    maxWaveParallelism: 2  # don't overwhelm the API server
    freezeUntil: "2026-04-01T00:00:00Z"  # merge freeze
```

Constraints live on the activation, not in a separate policy engine. The operator enforces them as part of the control loop. This keeps policy co-located with the deployment unit — different activations can have different policies (canary = aggressive, production = conservative).

### 4.7 Convergence proof

Because both the old and new state are complete, immutable closures, the operator can **prove convergence** before starting:

1. New closure is a valid Nix evaluation (type-checked, assertions passed at eval time)
2. Set-diff is finite and deterministic
3. Wave ordering is a topological sort of a DAG (acyclic by construction)
4. Each wave has a bounded timeout

If the operator starts a deploy, it either completes (all waves healthy) or halts at a known wave with a known set of changes applied. There's no "partially converged to an unknown state" — the operator always knows exactly which closure it's converged to.

---

## 5. Architecture Decisions

### 5.1 Where does nix eval happen?

| Option | Pros | Cons |
|--------|------|------|
| **Push-based (CI evals, operator deploys)** | Operator is simple, no nix dependency in-cluster, eval can use beefy CI machines | Extra CI step, latency between commit and deploy |
| **Pull-based (operator evals from git)** | True GitOps (single loop), no CI dependency | Needs nix in operator pod, resource-intensive in-cluster eval |
| **Hybrid (CI evals + caches, operator pulls cached result)** | Best of both: fast in-cluster, heavy eval offloaded | Needs a cache/registry (binary cache or OCI) |

**Recommendation:** Start push-based. CI runs `nix build .#cluster-X`, pushes the store path to a binary cache, updates the Activation CR's `spec.source.path`. The operator never runs nix — it reads manifests from the store path (via binary cache or mounted volume). Pull-based can come later.

### 5.2 How does the operator access Nix store paths?

The operator needs to read manifest JSON from store paths. Options:

1. **Nix binary cache** — operator fetches store paths from a cache (like `cachix` or `attic`). Standard nix tooling. Requires nix client in pod.
2. **OCI artifact** — CI packages the evaluated manifests as an OCI image/artifact. Operator pulls from registry. No nix dependency.
3. **packageIndex.json** — Already generated by `buildCluster`. Contains PI → resource mapping. CI can serialize this + all manifest files into a single artifact the operator consumes.
4. **ConfigMap/Secret** — For small clusters, embed the manifest set in a ConfigMap referenced by the Activation. Simple but doesn't scale.

**Recommendation:** Use `packageIndex.json` + serialized manifests as an OCI artifact. The operator pulls one artifact per activation, extracts the manifest set, and works entirely from that. No nix runtime needed in-cluster.

### 5.3 Shared resource ownership

When two activations reference the same resource (same content-hash):

- **Apply**: first activation to deploy it wins. Second activation sees it already exists with matching hash → skip.
- **Update**: if activation A updates a shared resource (new hash), activation B still references the old hash → conflict. Resolution: the resource moves to the new hash (latest activation wins), activation B is marked as needing reconciliation.
- **Delete**: reference-counted. Resource is pruned only when no activation references it.

Implementation: `kix.dev/activation-refs` annotation on each resource, maintained by the operator. This is the only mutable annotation the operator writes.

### 5.4 Failure strategies

| Strategy | Behavior | When to use |
|----------|----------|-------------|
| **halt** | Stop at failed wave, keep partial progress, alert | Production (default) |
| **rollback** | Revert to `status.previousHash` automatically | When rollback is known-safe (stateless services) |
| **continue** | Skip failed resources, proceed with remaining waves | Non-critical environments, testing |

Halt is the safe default. The operator records exactly which wave failed and which resources were applied, so recovery is always possible — either fix-forward (new activation) or rollback (update spec to previous hash).

---

## 6. Interaction with Existing kix Components

### What already exists and maps directly

| Component | Current state | Role in operator |
|-----------|--------------|------------------|
| `mkActivation` (k8s.nix) | Generates Activation CR with instance refs | The object the operator watches |
| `packageIndex.json` (cluster.nix) | PI → resource store path mapping | Manifest discovery |
| `graph.rs` (kix-cluster) | DAG from depends-on annotations | Wave computation |
| `waves.rs` (kix-cluster) | Kahn's algorithm toposort | Deploy ordering |
| `apply.rs` (kix-cluster) | SSA + content-hash change detection | Apply logic |
| `readiness.rs` (kix-cluster) | Per-kind health checks | Wave gates |
| `fetch.rs` (kix-cluster) | Fetch live managed resources | Drift detection |

### What needs to be built

| Component | Description |
|-----------|-------------|
| **Activation controller** | K8s controller watching Activation CRs, dispatching reconcile/GC |
| **Closure differ** | Given two activation hashes, compute added/removed/changed resource sets |
| **Multi-activation reference tracker** | Maintain `kix.dev/activation-refs` across activations |
| **History recorder** | Persist activation lineage (generation chain + timestamps + commits) |
| **Drift detector** | Periodic loop comparing live content-hash annotations against expected |
| **Manifest artifact puller** | Fetch evaluated manifests from OCI/cache given an activation hash |

Most of the hard reconciliation logic (waves, SSA, readiness) already exists in `kix-cluster`. The operator is primarily a **controller wrapper** around that existing engine, adding the activation lifecycle and multi-activation coordination.

---

## 7. CLI Integration

The operator is the in-cluster long-running version of what `kix deploy` does as a one-shot. They share the same engine:

```
                    ┌─────────────┐
                    │  kix engine  │  (Rust library)
                    │  diff, plan, │
                    │  apply, GC   │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
         kix deploy   kix operator   kix diff
         (one-shot)   (in-cluster)   (read-only)
```

- `kix deploy .#cluster-X` — evaluate, create/update Activation CR, apply (one-shot, like `kubectl apply` but with waves)
- `kix deploy --push .#cluster-X` — evaluate, push to artifact store, update Activation CR (let the operator do the apply)
- `kix status` — read Activation CR status, show deploy progress
- `kix rollback` — update Activation CR to previous hash
- `kix gc` — manual garbage collection (delete orphaned resources)

---

## 8. Sketch: A Deploy Scenario

### Initial deploy

```
$ kix deploy .#cluster-production

Evaluating cluster-production...
  47 resources in 6 waves

Activation: production (generation 1)
  Source: /nix/store/abc123...-activation-production

  Wave 0: 2 Namespaces                              ✓ ready
  Wave 1: 4 CRDs                                    ✓ established
  Wave 2: 8 ServiceAccounts, 3 ConfigMaps, 2 Secrets ✓ ready
  Wave 3: 5 RBAC resources                           ✓ ready
  Wave 4: 3 Services, 4 Deployments, 1 StatefulSet   ✓ healthy
  Wave 5: 2 Ingresses                                ✓ ready

  47 applied, 0 pruned, 0 unchanged
  Activation production@gen1 → Healthy
```

### Update (one package version bumped)

```
$ kix deploy .#cluster-production

Evaluating cluster-production...
  47 resources in 6 waves

Activation: production (generation 2)
  Previous: /nix/store/abc123...
  New:      /nix/store/def456...

  Closure diff:
    42 unchanged (same content-hash)
     3 changed   (app Deployment, app ConfigMap, app Service)
     2 added     (new migration Job, new ConfigMap)
     2 removed   (old migration Job, deprecated ConfigMap)

  Wave 0–3: skipped (all unchanged)                  ✓
  Wave 4:   1 Deployment, 1 ConfigMap, 1 Service     ✓ healthy
  Wave 5:   skipped (unchanged)                      ✓
  Prune:    2 resources (reverse order)              ✓

  3 applied, 2 added, 2 pruned, 42 unchanged
  Activation production@gen2 → Healthy
```

### Canary

```
$ kix deploy .#cluster-production-canary --name canary-v2

Activation: canary-v2 (generation 1)
  Base: production@gen2

  Closure diff (against shared resources):
    44 shared with production (same hash → skip)
     3 unique to canary (Deployment/app-canary, Service/app-canary, Ingress/app-canary)

  Wave 4: 1 Deployment, 1 Service     ✓ healthy
  Wave 5: 1 Ingress                   ✓ ready

  3 applied, 44 shared
  Activation canary-v2@gen1 → Healthy

$ kubectl delete activation canary-v2

  GC: 3 resources unique to canary-v2 removed
  44 shared resources retained (still referenced by production)
```

---

## 9. Open Questions

1. **Activation granularity** — one activation per cluster, or allow sub-cluster activations (e.g., per-namespace, per-team)? Per-cluster is simpler and aligns with how `buildCluster` works today. Sub-cluster activations would require splitting the evaluation, which changes the module system semantics.

2. **Cross-activation resource conflicts** — if activation A and activation B both produce a resource at the same name but with different content-hashes, who wins? Options: (a) reject the second activation (conflict error), (b) latest-write-wins with annotation, (c) require explicit ownership declaration. This matters for the PR preview and canary use cases.

3. **Nix store path stability** — store paths change when any input changes. If a global label changes, every resource gets a new hash even if the meaningful content didn't change. `identity-hash` (stable across content changes) vs `content-hash` (changes with content) distinction already exists — the diff should use identity-hash for matching and content-hash for change detection.

4. **Operator bootstrap** — the operator needs to be deployed before it can manage activations. But we want the operator itself to be kix-managed. Chicken-and-egg. Solution: the operator is the one resource deployed by `kix deploy` (CLI), everything else is operator-managed. Or: the operator self-adopts after first manual deploy.

5. **Activation size limits** — for large clusters, the Activation CR's `spec.instances` could get large. The CR itself is fine (etcd limit is 1.5MB), but the manifest artifact could be significant. May need chunking or external reference.

6. **Secret handling** — secrets in the manifest set need encryption at rest. The activation artifact should either exclude secrets (injected separately) or encrypt them (agenix-style). This intersects with the secrets DI design (doc 22).
