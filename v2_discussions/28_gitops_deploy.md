# kix deploy — GitOps Feature Parity RFC

## Working Document — March 2026

**Status:** Design exploration
**Related:** `10_merkle_dag_package_instance.md` (PackageInstance CRD, DAG), `06_team_dx_multi_deploy.md` (multi-deploy), ROADMAP.md (deploy section), MAJOR_FEATURES.md (content-addressing use-cases)

---

## 1. Goal

`kix deploy` should be a complete GitOps deployment tool — not a wrapper around `kubectl apply`. The target is full feature parity with Flux and Argo CD, but designed around kix's content-addressed, functionally-pure evaluation model rather than bolted on after the fact.

This RFC first maps the complete GitOps feature surface, then shows how kix's existing design primitives cover (or don't cover) each feature, and finishes with a focused roadmap to a deployable MVP.

---

## 2. The GitOps Feature Surface

What Flux and Argo CD provide, grouped by concern:

### 2.1 Reconciliation

| Feature | Description |
|---|---|
| **Continuous reconciliation** | Periodically compare desired state against live state, apply differences |
| **Self-healing** | Detect and revert manual changes to managed resources |
| **Drift detection** | Surface differences between desired and actual state |
| **Retry with backoff** | Automatically retry on transient failures (API server down, CRD not installed yet) |
| **Suspend/resume** | Pause reconciliation without removing resources |

### 2.2 Resource Lifecycle

| Feature | Description |
|---|---|
| **Ordered apply (waves/phases)** | Deploy resources in dependency order |
| **Pruning** | Delete resources no longer in desired state |
| **Server-side apply** | Use SSA for proper field ownership, avoiding last-writer-wins conflicts |
| **Health assessment** | Per-resource-type health checks (Deployment rollout complete, StatefulSet ready, Job succeeded) |
| **Health gates between waves** | Block next wave until previous wave is healthy |
| **Sync hooks** | PreSync/PostSync/SyncFail jobs (migrations, smoke tests, alerts) |
| **Finalizers / pre-delete hooks** | Cleanup logic before resource removal |

### 2.3 Observability

| Feature | Description |
|---|---|
| **Deploy status** | Real-time per-resource sync state (synced, progressing, degraded, failed, pruned) |
| **Deploy history** | Log of what was deployed when, with what version/hash |
| **Event notifications** | Webhook/Slack on deploy events (started, succeeded, failed) |

### 2.4 Safety & Policy

| Feature | Description |
|---|---|
| **Diff preview** | Show what will change before applying |
| **Manual approval gates** | Require human sign-off for certain changes |
| **Apply-time validation** | Server-side dry-run before actual apply |
| **Sync windows** | Restrict when deploys can happen |
| **Scoped permissions** | Who can deploy what, to which namespaces |

### 2.5 Artifact & Image Management

| Feature | Description |
|---|---|
| **Git source** | Pull desired state from a git repository |
| **OCI source** | Pull desired state from an OCI registry |
| **Image update automation** | Watch container registries, auto-update tags/digests |

### 2.6 Multi-Tenancy & Scale

| Feature | Description |
|---|---|
| **Multi-cluster** | Manage multiple clusters from one source |
| **Namespace isolation** | Per-team blast radius limits |
| **Application grouping** | Logical grouping of related resources (Argo Application, Flux Kustomization) |

---

## 3. How kix's Design Primitives Map to GitOps Features

The core insight: content-addressing, the Merkle DAG, and functional purity make many GitOps features either trivial or fundamentally different from how Flux/Argo implement them.

### 3.1 Content-Addressing → Reconciliation becomes hash comparison

**What it solves:** Continuous reconciliation, self-healing, drift detection, deploy history.

In Flux/Argo, reconciliation is "diff the YAML." In kix, every resource carries a `kix.dev/content-hash` annotation. Reconciliation reduces to:

```
for each resource in eval output:
  live_hash = get annotation from live resource
  if live_hash != expected_hash:
    re-apply
```

Self-healing is the same loop — if someone manually edits a resource, the content hash on the live object no longer matches. No YAML diffing needed.

Deploy history is a sequence of root hashes: `(timestamp, root-hash, git-commit)`. The root hash is deterministic from the eval. Rolling back = pointing to a previous root hash.

**Difficulty:** Trivial. The mechanism already exists (content-hash annotations are generated today). The missing piece is the reconciliation loop itself.

**What it does NOT solve:** Health assessment. A matching hash means "the manifest is correct," not "the workload is running." Health is a runtime property that must be checked separately.

### 3.2 Merkle DAG → Ordered deployment falls out of the dependency graph

**What it solves:** Ordered apply (waves), sync hooks (PreSync/PostSync), application grouping.

The store-path DAG already encodes the full dependency order. Wave rollouts are a topological sort of the DAG. A "PreSync migration Job" is just a resource that sits earlier in the DAG than the Deployment that depends on it — no separate hook mechanism needed.

The PackageInstance CRD (doc 10) already serves as the "Application" grouping — it's the root of each package's subgraph. Resources belong to the PackageInstance that roots their DAG subtree.

**Difficulty:** Easy. The DAG exists; wave computation is a topological sort. The only new code is the deploy loop that walks waves.

**What it does NOT solve:** Health gates between waves. The DAG tells you *what order* to apply, but not *when to proceed*. Between waves, you need an imperative health-check loop. Also does not solve SyncFail hooks (reactive, not graph-ordered).

### 3.3 Functional Purity → Diffing and validation are free

**What it solves:** Diff preview, apply-time validation (partial), deploy status.

`kix-diff` already exists and compares evaluated output against a live cluster dump. Since evaluation is pure and deterministic, the diff is always accurate — there's no "it worked on my machine" divergence between what you diffed and what gets applied.

Deploy status per resource is straightforward: each resource has a known hash and known wave position. Query K8s for each, bucket by state.

**Difficulty:** Trivial for diff (exists). Easy for status reporting.

**What it does NOT solve:** Server-side dry-run (requires API server access, which is imperative). But `kubectl apply --dry-run=server` is a one-liner to add.

### 3.4 PackageInstance CRD → Pruning via ownership tracking

**What it solves:** Pruning, garbage collection.

This is where content-addressing creates a unique challenge AND a unique solution. Because resource names include their content hash, an *update* produces a new resource (new hash) alongside the old one. Pruning the old hash is how "updates" work in kix — it's not an edge case, it's the normal path.

The PackageInstance CRD tracks which resources belong to each package instance. After a new eval:

1. Compute the new set of resource hashes per PackageInstance
2. Compare against the old set (stored on the live PackageInstance)
3. Resources in old set but not new set → prune

This is cleaner than Flux/Argo's label-based ownership because the DAG explicitly tracks membership — no label selector matching needed.

**Difficulty:** Medium. The PackageInstance CRD exists. The new code is: (a) persisting the resource set on the PackageInstance, (b) computing the diff, (c) deleting orphans. The tricky part is ordering: new resources must be healthy before old ones are pruned (otherwise you have a gap).

### 3.5 What kix does NOT make easier

These features are inherently imperative and don't benefit from kix's functional model:

| Feature | Why it's hard | Approach |
|---|---|---|
| **Health assessment** | Runtime property, not build-time | Implement per-resource-type health checks (Deployment: `.status.conditions`, Job: `.status.succeeded`, etc.). Standard K8s API polling. |
| **Health gates** | Imperative wait loop | Poll health between waves, with timeout. |
| **Retry with backoff** | Standard engineering | Exponential backoff on API errors. |
| **Notifications** | Side effect | Webhook call on state transitions. |
| **Sync windows** | Time check | Guard clause before reconciliation. |
| **Image update automation** | Registry watching is imperative | Watch registries, update flake inputs, trigger re-eval. The *propagation* through the DAG is trivial (change input → all dependent hashes change), but the *watcher* is imperative. |
| **Finalizers / pre-delete** | Deletion is imperative | Run cleanup logic before pruning. Hard to express in a pure system — needs an escape hatch. |
| **Suspend/resume** | State flag | Trivial, just skip the reconciliation loop. |

---

## 4. The kix Deploy Architecture

Based on the mapping above, `kix deploy` has three layers:

```
┌─────────────────────────────────────┐
│         Reconciliation Loop         │  ← Continuous: git watch / timer
│  eval → diff → plan → apply → heal │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│          Wave Engine                │  ← DAG toposort → ordered waves
│  for each wave:                     │
│    apply resources                  │
│    wait for health                  │
│    on failure: halt / retry / alert │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│        Resource Lifecycle           │  ← Per-resource: SSA, health, prune
│  server-side apply                  │
│  health polling                     │
│  orphan detection + deletion        │
└─────────────────────────────────────┘
```

### Reconciliation loop

1. **Trigger:** git commit, timer, or manual invocation
2. **Eval:** `nix eval .#cluster-<name>` → full set of store paths (manifests)
3. **Diff:** Compare content hashes of eval output against live cluster annotations
4. **Plan:** Compute which resources need creating, updating, or pruning
5. **Apply:** Walk the wave engine
6. **Report:** Emit status, update deploy history, send notifications

### Wave engine

1. Topological sort of the resource DAG → assign wave numbers
2. For each wave (ascending):
   a. Apply all resources in this wave (server-side apply, parallel within wave)
   b. Wait for health (per-resource-type checks, configurable timeout)
   c. On timeout/failure: halt, retry, or continue based on policy
3. After all waves complete: prune orphaned resources from previous eval

### Resource lifecycle

- **Apply:** `kubectl apply --server-side` with force-conflicts (kix owns all fields it manages)
- **Health:** Poll `.status` per resource type. Deployment: available replicas = desired. StatefulSet: ready replicas = desired. Job: succeeded = 1. Custom resources: check `.status.conditions` for `Ready=True`
- **Prune:** Delete resources whose hashes appear in the old PackageInstance but not the new one. Reverse wave order (dependents before dependencies).

---

## 5. Roadmap to GitOps MVP

### Milestone 1: "It deploys and prunes" (the minimum viable loop)

This is the point where `kix deploy` replaces `kubectl apply -f result/` and you can stop using Flux/Argo for basic cases.

| Item | Difficulty | Notes |
|---|---|---|
| **Server-side apply** | Trivial | Use `kubectl apply --server-side` instead of client-side. Default from day one. |
| **Wave engine** | Easy | Topological sort of DAG → wave assignment. Apply in order. Already have the DAG. |
| **Pruning by hash ownership** | Medium | Track resource set on PackageInstance. After apply, delete resources in old set but not new set. Reverse wave order for deletion. |
| **Basic health checks** | Medium | Deployment, StatefulSet, DaemonSet, Job. Poll `.status` with timeout. Block between waves. |
| **Deploy status CLI output** | Easy | Print per-resource status during deploy. Colorized table: resource, wave, state. |

**"Done" looks like:** `kix deploy .#cluster-nw1` applies resources in dependency order, waits for each wave to be healthy, prunes resources that disappeared from the eval, and prints a status summary. No manual `kubectl delete` of old resources.

### Milestone 2: "It self-heals" (continuous reconciliation)

This is the point where `kix deploy` is a running process, not a one-shot command.

| Item | Difficulty | Notes |
|---|---|---|
| **Continuous reconciliation loop** | Easy | Re-eval on timer or git webhook. Compare content hashes against live. Re-apply drifted resources. |
| **Self-healing** | Trivial (on top of M1) | Same as reconciliation — if live hash ≠ expected hash, re-apply. Falls out of the loop. |
| **Drift detection reporting** | Easy | `kix status` command showing which resources have drifted. |
| **Retry with backoff** | Easy | Wrap apply in exponential backoff for transient API errors. |

**"Done" looks like:** `kix deploy --watch .#cluster-nw1` runs continuously. Someone `kubectl edit`s a resource → kix detects the hash mismatch within the next reconciliation interval → reverts it. Transient API failures don't crash the loop.

### Milestone 3: "It's safe for production" (guardrails)

| Item | Difficulty | Notes |
|---|---|---|
| **Diff preview before apply** | Easy | `kix diff` already exists. Wire it into the deploy flow as a pre-apply step with `--dry-run` flag. |
| **Apply-time server-side dry-run** | Trivial | `kubectl apply --dry-run=server` before actual apply. Catches quota/admission issues. |
| **Manual approval gates** | Easy | For specified namespaces or resource types, pause and prompt before applying. Interactive in CLI, webhook in CI. |
| **Deploy history** | Trivial | Log `(timestamp, root-hash, git-commit, user)` to a local file or ConfigMap. Rollback = `kix deploy --to-hash <hash>`. |
| **Suspend/resume** | Trivial | Flag that skips reconciliation. `kix suspend <instance>` / `kix resume <instance>`. |

**"Done" looks like:** `kix deploy --dry-run` shows the full plan without applying. Deploying to production requires approval. You can `kix rollback` to a previous deploy. You can suspend a misbehaving package without removing it.

### Milestone 4: "It replaces Flux/Argo" (full feature parity)

| Item | Difficulty | Notes |
|---|---|---|
| **Notifications** | Easy | Webhook on state transitions (deploy started/succeeded/failed). Slack/generic HTTP. |
| **Sync windows** | Trivial | Time-of-day guard before reconciliation. |
| **Scoped deploy permissions** | Easy | Static analysis of eval output: which namespaces, which resource types. Compare against allowed set per deployer. Uniquely easy in kix because the full output is known at eval time. |
| **Image update automation** | Medium | Registry watcher → update flake input → trigger re-eval. Propagation through DAG is automatic. |
| **Pre-delete hooks** | Medium | Run cleanup Jobs before pruning stateful resources. Package `meta.lifecycle = "stateful"` already marks these. |
| **Multi-cluster** | Medium | Already modeled: multiple cluster definitions in `clusters/`. Deploy loop targets a kubeconfig context per cluster. Shared packages, different instance configs. |
| **OCI artifact source** | Medium | Push eval output to OCI registry. Deploy loop pulls from OCI instead of running nix eval. Decouples eval from deploy. |

---

## 6. What kix should NOT copy from Flux/Argo

Some Flux/Argo features exist because of limitations in their architecture that kix doesn't share:

- **Kustomize/Helm source abstractions** — kix IS the templating layer. No need to wrap another renderer.
- **Application-of-applications pattern** (Argo) — kix's module system handles composition natively. PackageInstance is the grouping.
- **Label-based resource ownership** — kix has content-hash-based ownership via the DAG. Labels are for humans, not for the deploy tool.
- **Separate "sync" vs "refresh"** (Argo) — in kix, eval is always complete (functional purity). There's no stale cache to refresh.
- **Jsonnet/plain-YAML source types** — kix evaluates Nix. One input format.

---

## 7. Open Questions

1. **Where does the reconciliation loop run?** Options: (a) `kix deploy --watch` as a long-running CLI process, (b) a kix-operator pod in-cluster (Argo model), (c) a CI job on a cron (Flux model with push). Likely all three eventually, but what's the MVP?

2. **Pruning safety for stateful resources.** Content-addressing means a config change to a StatefulSet produces a *new* StatefulSet (new hash). Pruning the old one deletes the workload. For stateless resources this is fine (new one is already running). For stateful resources (PVCs, databases), pruning = data loss. Need a policy: auto-prune stateless, prompt for stateful (use `meta.lifecycle`).

3. **Health check extensibility.** Built-in checks cover standard K8s types. CRDs need custom health checks — where do these live? Options: (a) on the package definition (`meta.healthCheck`), (b) on the CRD ref, (c) convention-based (always check `.status.conditions`).

4. **Interaction with content-addressed naming.** If resource names include hashes, standard K8s rolling updates don't apply (you can't update a Deployment in-place — the name changed). The wave engine needs to handle "create new, wait healthy, prune old" as the *normal* update path, not just for stateful migrations. This is a feature (zero-downtime by default) but also a complexity (every update is a blue-green deploy).

5. **Eval performance under continuous reconciliation.** Re-evaluating the full cluster on every reconciliation tick could be slow. Options: (a) content-hash the nix inputs and skip eval if unchanged, (b) incremental eval (hard in Nix), (c) cache the eval output and only re-eval on git change.
