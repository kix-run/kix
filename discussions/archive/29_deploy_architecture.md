# kix Deploy & Lifecycle — Architectural Design

## Working Document — March 2026

**Status:** Architecture reference
**Related:** `28_gitops_deploy.md` (feature surface / GitOps RFC), `10_merkle_dag_package_instance.md` (DAG), `00_kix_v2.md` (content-addressing fundamentals)

---

## 1. Purpose

Doc 28 maps the *feature surface* (what a GitOps tool needs to do). This document is the *how it actually works* reference — the pipeline from Nix eval to running resources, the data model, the state machines, and the failure modes. It is grounded in the working prototype built against kind, warts included, and designs forward from there.

---

## 2. Pipeline Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                          kix deploy <cluster>                        │
└──┬───────────────────────────────────────────────────────────────────┘
   │
   ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  nix build   │────▶│  Store Graph │────▶│    Stamp      │
│  activation  │     │  (DAG load)  │     │  (CLI-owned)  │
└──────────────┘     └──────────────┘     └──────┬───────┘
                                                  │
   ┌──────────────────────────────────────────────┘
   ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Local Diff  │────▶│  Diff Waves  │────▶│   Apply       │
│  (old↔new)   │     │  (toposort)  │     │  (SSA/wave)   │
└──────────────┘     └──────────────┘     └──────┬───────┘
                                                  │
   ┌──────────────────────────────────────────────┘
   ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Readiness   │────▶│  Activation  │────▶│  Prune Wave   │
│  (per-wave)  │     │  Lifecycle   │     │  (orphans)    │
└──────────────┘     └──────────────┘     └──────────────┘
```

**Invariant:** The CLI owns all stamping and annotation logic. The Nix side produces raw manifests and the store DAG. `pipeline/annotate.py` is legacy — to be removed once the CLI handles all output paths (build, diff, deploy).

---

## 3. Stage Details

### 3.1 Nix Build

**Input:** `nix build .#cluster-<name>-activation`

**Output:** A result directory containing:
- `activation` — symlink to the Activation store path (root of the DAG)
- `kix-packages.json` — index: `{ packages: { <PI store path>: { instance_name, namespace, resource_paths: [...] } } }`

The Activation store path is the Merkle root. Every resource in the cluster is transitively reachable from it via `nix-store --query --references`. The result directory is the serialized form of a complete cluster state.

**What Nix guarantees:**
- Deterministic evaluation — same inputs = same store paths = same manifests
- Dependency completeness — the store closure contains everything, nothing is missing
- Content identity — the store hash of each resource is a function of its manifest content + its dependencies' store hashes

**What Nix does NOT do:**
- Stamping (annotations added by CLI)
- Change detection (that's a local DAG diff, see §3.5)

### 3.2 Store Graph Load

**Input:** Result directory from `nix build`

**Process:**
1. Read `kix-packages.json` → package index (PI → resource paths)
2. Resolve `activation` symlink → Activation store path
3. Run `nix-store -q --graph <activation-path>` → bulk-load the full DAG as a directed graph
4. Parse the dot output into a `ref_cache: HashMap<PathBuf, Vec<PathBuf>>` where each entry is `dependent → [dependencies]`
5. Read each store path's JSON manifest into memory
6. Discover cluster-level resources (Namespaces, CRDs, Activation) by scanning all DAG paths for k8s store paths not owned by any PI

**Edge direction clarification:**
In the Nix store DAG (from `nix-store -q --graph`), an edge `A → B` means "A is a reference of B" / "B depends on A" / "A is a dependency of B". The `ref_cache` inverts this to store `dependent → [dependencies]` for intuitive lookup.

**Output:** `StoreGraph` containing:
- `packages: IndexMap<PathBuf, PackageNode>` — PI store paths → metadata + resource paths
- `resources: HashMap<PathBuf, ResourceNode>` — all k8s store paths → manifests
- `ref_cache: HashMap<PathBuf, Vec<PathBuf>>` — dependency edges (dependent → deps)
- `cross_deps` — cross-package dependency edges
- `cluster_name: String`

### 3.3 Stamping (CLI-Owned)

The CLI stamps annotations onto each manifest. These are the deployment engine's contract — everything downstream reads these annotations, never raw store paths.

| Annotation | Source | Purpose |
|---|---|---|
| `kix.dev/identity-hash` | First 32 chars of the store path basename | Stable identity for a resource. Same identity-hash = same Nix store path = identical content+deps. Used for change detection (local DAG diff) and GC (comparing old vs new sets). |
| `kix.dev/depends-on` | Comma-separated identity-hashes of dependencies from the store graph | Deployment ordering. The resource cannot be applied until all resources in its depends-on list are applied and healthy. |
| `kix.dev/package` | Instance name from PackageNode | Ownership. Which PackageInstance this resource belongs to. `_cluster` for cluster-level resources (CRDs, Namespaces, Activation). |
| `kix.dev/activations` | Comma-separated activation identity-hashes | Multi-activation ownership. Lists all activations that claim this resource. Used by GC to avoid pruning resources shared across activations (see §5.4). |

**Additional labels:**
| Label | Value | Purpose |
|---|---|---|
| `app.kubernetes.io/managed-by` | `kix` | Cluster-wide discovery of all kix-managed resources |

**Stamping for package-owned resources:** Dependencies come from `cross_pkg_refs` (cross-package store references resolved via the ref_cache).

**Stamping for cluster-level resources:** Dependencies come from direct ref_cache lookup (e.g., PackageInstance depends on the PackageInstance CRD and its Namespace).

### 3.4 Resource Graph & Waves

**Input:** Stamped manifests

**Graph construction:**
1. Parse `kix.dev/identity-hash` from each manifest → graph node
2. Parse `kix.dev/depends-on` → graph edges
3. Validate: detect cycles, dangling references

**Wave computation (Kahn's algorithm):**
1. Wave 0 = nodes with no dependencies (leaves: CRDs, Namespaces)
2. Wave N+1 = nodes whose dependencies are all in waves 0..N
3. Within each wave, sort **lexicographically** by `kind/namespace/name` (for determinism only — the DAG guarantees all resources in a wave are fully independent, so ordering within a wave has no correctness implications)

**Result:** `Vec<Vec<NodeIndex>>` — ordered waves of parallel-deployable resources.

### 3.5 Change Detection (Local DAG Diff)

Change detection is a **local operation** — it diffs two Nix store graphs without querying the cluster. The deploy engine trusts its own state: "I deployed activation X, now I'm deploying activation Y, the diff is Z."

**Input:**
- Old activation: from the `Active` Activation CR on the cluster (looked up by `kix.dev/cluster` label), then resolved to a local Nix store graph via identity-hash. On first deploy (no previous activation), all resources are treated as creates.
- New activation: freshly built (`nix build`)

**Diff algorithm:**
Match resources by Kubernetes identity (`kind + namespace + name`):

| Old graph | New graph | Action |
|---|---|---|
| absent | present | **Create** — new resource |
| present (same identity-hash) | present (same identity-hash) | **Skip** — identical content+deps, nothing to do |
| present (different identity-hash) | present (different identity-hash) | **Update** — same K8s resource, content changed |
| present | absent | **Orphan** — resource removed from desired state |

**Diff waves:**
- **Create** and **Update** resources are assigned to waves computed from the *new* DAG's topological order (Kahn's algorithm, §3.4). Only waves that contain at least one Create or Update are executed.
- **Orphan** resources are pruned *after* all apply waves complete, in **reverse topological order** of the *old* DAG (dependents first, then their dependencies). This prevents dangling references during deletion.
- Pruning after apply is the default (safer — old resources remain during transition, enabling easy rollback). A `--prune=eager` flag may interleave prune waves for cases where old resources conflict with new ones (e.g., renamed ClusterRoles). A `--prune=no` flag skips pruning entirely, deferring cleanup to `kix gc`.

### 3.6 Apply (Server-Side Apply)

- Method: `kubectl apply --server-side` with field manager `"kix"` and `force=true`
- kix owns all fields it manages. Other tools (Prometheus, users) can own other fields.
- SSA is the default update model. Resources keep stable names.

**Multi-activation stamping:** During apply, the engine reads the existing `kix.dev/activations` annotation on the live resource (if any), merges in the current activation's identity-hash, and writes the union. This handles shared resources across activations (see §5.4). Uses optimistic concurrency via `resourceVersion` — if a concurrent deploy races on the same resource, retry with the merged annotation.

**CRD re-discovery:** After any wave that creates `CustomResourceDefinition` resources, the CLI re-runs API discovery so subsequent waves can apply custom resources.

### 3.7 Readiness

After applying a wave, the engine waits for every resource in that wave to be ready before proceeding to the next wave.

**Per-kind readiness checks:**

| Kind | Check | Ready when |
|---|---|---|
| ConfigMap, Secret, ServiceAccount, Namespace, Service, RBAC, PVC, NetworkPolicy, PackageInstance, Activation | Immediate | Exists after apply |
| CustomResourceDefinition | Condition | `status.conditions[Established] = True` |
| Deployment | Status | `observedGeneration == generation` AND `readyReplicas >= replicas` |
| StatefulSet | Status | `observedGeneration == generation` AND `readyReplicas >= replicas` |
| DaemonSet | Status | `observedGeneration == generation` AND `numberReady >= desiredNumberScheduled` |
| Job | Status | `status.succeeded >= 1` |
| Generic CR | Convention | `status.conditions[Ready].status = "True"` (fallback: existence) |

**Timeout:** Default 5 minutes, configurable via `--timeout`.
**Poll interval:** 2 seconds.
**Failure modes:** `--on-error stop` (default) halts the deploy. `--on-error continue` logs the failure and proceeds.

---

## 4. Activation Lifecycle

The Activation CR is the cluster-level record of "what is deployed." It replaces ad-hoc state tracking.

### 4.1 Activation CRD Schema

```yaml
apiVersion: kix.dev/v1alpha1
kind: Activation
metadata:
  name: <cluster-name>-<generation>  # e.g., "nw1-00042"
  labels:
    app.kubernetes.io/managed-by: kix
    kix.dev/cluster: <cluster-name>
  annotations:
    kix.dev/identity-hash: <store-hash>    # first 32 chars of store path basename; resolves to /nix/store/<hash>-...
    kix.dev/previous: <previous-identity-hash>  # chain for GC + rollback
    kix.dev/deployed-at: <RFC3339 timestamp>
    kix.dev/git-commit: <commit-sha>       # if available
spec:
  cluster: <cluster-name>
  active: true  # false = deactivated (pending GC or kept for rollback)
  instances:
    <namespace>:
      <instance-name>: <PI resource name>
status:
  phase: Active | Superseded | RollingBack | GarbageCollecting
  observedGeneration: <int>
```

### 4.2 State Machine

```
                    deploy succeeds
                   ┌─────────────┐
                   │             ▼
              ┌─────────┐   ┌─────────────┐
  deploy ───▶│  Active  │   │ Superseded  │──── kix gc ────▶ (deleted)
              └─────────┘   └─────────────┘
                   │              ▲
                   │  new deploy  │
                   └──────────────┘
                         │
                    kix rollback
                         │
                         ▼
                   ┌──────────────┐
                   │ RollingBack  │───▶ Active (old becomes active,
                   └──────────────┘      new becomes Superseded)
```

**Deploy flow:**
1. Before applying, read the current `Active` Activation for this cluster (if any)
2. Compute local DAG diff between old and new activation (§3.5)
3. Create a new Activation with `active: true`, `previous: <old-identity-hash>`
4. Set the old Activation to `active: false`, `phase: Superseded`
5. Apply diff waves (creates and updates), then prune orphans
6. After success, save new activation identity-hash locally for cache

**Rollback flow:**
1. `kix rollback <cluster>` lists Superseded Activations
2. User selects one
3. Resolve its identity-hash to a local Nix store path, load the store graph
4. Re-deploy from that store graph (same pipeline as deploy)
5. Current Active becomes Superseded, rolled-back one becomes Active

**Key property:** Activations are never deleted by deploy — only deactivated. `kix gc` is the only thing that removes them (and their orphaned resources).

### 4.3 Local State Cache

`~/.cache/kix/activations/<cluster>.hash` — the identity-hash of the last-deployed activation. Used for:
- Quick re-entry to the store graph without querying the cluster for the Active Activation
- Resolves to a local Nix store path for DAG diff

This is a **performance cache**, not the source of truth. The source of truth is the Activation CR on the cluster.

---

## 5. Garbage Collection

### 5.1 Soft GC (default)

**Principle:** Diff two Nix store graphs locally. No cluster-wide resource scan. This is the same diff that deploy computes (§3.5) — soft GC is essentially "deploy's prune phase, run separately."

**Input:**
- Old activation: from the Superseded Activation CR on the cluster (resolved to a local Nix store path via identity-hash), or from the local cache (`~/.cache/kix/activations/<cluster>.hash`)
- New activation: the current Active activation (freshly built or cached)

**Algorithm:**
```
old_identities = { identity_hash(path) for path in old_graph.resources }
new_identities = { identity_hash(path) for path in new_graph.resources }
garbage = old_identities - new_identities
```

**Multi-activation check:** Before deleting a resource, read its `kix.dev/activations` annotation on the cluster. Remove the current activation from the set. If other activations still claim it, skip deletion (see §5.4).

**Deletion order:** Reverse topological order from the old graph (dependents first, then their dependencies). This prevents dangling references during deletion.

**What it catches:** Resources that were in the previous deploy but are no longer in the current one. The precise, targeted cleanup.

**What it misses:** Manually created kix-labeled resources. Resources from a different cluster deployed to the same K8s cluster. Stale resources from deploys before the cached one.

### 5.2 Hard GC (`--hard`)

**Principle:** Full cluster scan. The expensive but comprehensive sweep.

**Algorithm:**
```
# Collect expected identity-hashes from ALL active activations on this cluster
expected = union({ identity_hash for each resource in activation.store_graph }
                 for activation in active_activations
                 where activation.cluster == target_cluster)
live = fetch all resources with label managed-by=kix AND kix.dev/cluster=<target>
garbage = { r in live | r.identity_hash not in expected }
```

**Also catches:**
- Stale Activations from renamed/removed clusters
- Manually created resources with kix labels
- Resources from any previous deploy, not just the cached one

**Cost:** One LIST call per API resource type on the cluster. Expensive on large clusters with many CRDs.

**Multi-cluster safety:** Hard GC scopes by `kix.dev/cluster` label. Resources from cluster A are never GC'd when running GC for cluster B.

### 5.3 GC and Activation Interaction

GC reads Superseded Activations. For each:
1. Resolve the identity-hash to a local Nix store path, load the store graph
2. Identify resources in the Superseded activation not present in any Active activation
3. For shared resources (multiple entries in `kix.dev/activations`), remove the Superseded activation from the annotation instead of deleting the resource
4. Delete unshared orphaned resources (reverse topological order)
5. After all resources are cleaned up, delete the Superseded Activation CR itself (or keep it as a tombstone with a TTL if rollback history is desired)

### 5.4 Multi-Activation Resource Ownership

When multiple activations deploy to the same K8s cluster, they may produce identical resources (e.g., a shared postgres instance). The `kix.dev/activations` annotation tracks which activations claim each resource.

**Annotation format:**
```yaml
annotations:
  kix.dev/activations: "abc123,def456"  # comma-separated identity-hashes
```

**Deploy path:** When applying a resource, read the existing `kix.dev/activations` annotation (if the resource already exists on the cluster). Merge in the current activation's identity-hash. Write the union back. Uses optimistic concurrency via `resourceVersion` — if a concurrent deploy races, retry with merged annotation.

**GC path:** When considering a resource for deletion, remove the GC'd activation from `kix.dev/activations`. If the set becomes empty, delete the resource. If other activations still claim it, update the annotation and leave the resource in place.

**Invariant:** A resource is only deleted when no active activation claims it. This prevents one activation's GC from breaking another activation's resources.

---

## 6. Drift Detection (Out of Scope)

Content-hash normalization — comparing the intended manifest against the live resource's server-enriched representation — is **not part of the deploy or GC pipeline**. Deploy uses a local DAG diff (§3.5): it compares two Nix store graphs by identity-hash, which is a pure local operation. GC compares identity-hash sets. Neither needs to parse or normalize live resource content.

Drift detection ("has someone manually changed a resource since kix last applied it?") is a separate concern that requires content-hash normalization to handle server defaults, managed fields, and status stripping. It will be designed in a dedicated document when the reconciliation loop (§10.3) or `kix drift` command is implemented.

---

## 7. Data Model — CRD Schemas

### 7.1 PackageInstance CRD

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: packageinstances.kix.dev
spec:
  group: kix.dev
  scope: Namespaced
  names:
    kind: PackageInstance
    plural: packageinstances
    singular: packageinstance
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                instanceName:
                  type: string
                namespaceName:
                  type: string
                version:
                  type: string
            status:
              type: object
              x-kubernetes-preserve-unknown-fields: true
```

**Instance example:**
```yaml
apiVersion: kix.dev/v1alpha1
kind: PackageInstance
metadata:
  name: echo-server
  namespace: echo
  labels:
    app.kubernetes.io/managed-by: kix
  annotations:
    kix.dev/identity-hash: "1v0zxm07is8jiyg2vcar..."
    kix.dev/activations: "x7k2m9p1..."  # activation(s) claiming this resource
    kix.dev/root: echo-server  # the main resource
    kix.dev/depends-on: "n9n2qwqv..."  # CRD dependency
spec:
  instanceName: echo-server
  namespaceName: echo
  version: "1.27"
```

### 7.2 Activation CRD

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: activations.kix.dev
spec:
  group: kix.dev
  scope: Cluster
  names:
    kind: Activation
    plural: activations
    singular: activation
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                cluster:
                  type: string
                active:
                  type: boolean
                instances:
                  type: object
                  x-kubernetes-preserve-unknown-fields: true
            status:
              type: object
              properties:
                phase:
                  type: string
                  enum: [Active, Superseded, RollingBack, GarbageCollecting]
                observedGeneration:
                  type: integer
```

### 7.3 Annotation Contracts

These annotations form the API between the Nix evaluation layer and the CLI deploy engine. Any tool that reads kix-managed resources can rely on these.

| Annotation | On | Format | Semantics |
|---|---|---|---|
| `kix.dev/identity-hash` | All resources | `[a-z0-9]{32}` | Stable identity derived from the Nix store hash. Same identity = same store path = identical content+deps. Used for change detection (local DAG diff) and GC. |
| `kix.dev/depends-on` | Resources with deps | Comma-separated identity-hashes | Resources that must be applied and healthy before this one. Defines the DAG edges. |
| `kix.dev/package` | All resources | Instance name or `_cluster` | Which PackageInstance owns this resource. |
| `kix.dev/activations` | All resources | Comma-separated identity-hashes | Which activations claim this resource. Enables multi-activation GC (§5.4). |
| `kix.dev/previous` | Activation | Identity-hash | Chain to the previous Activation. Enables GC and rollback. |
| `kix.dev/root` | PackageInstance | Resource name | The main resource of this package instance. |

---

## 8. Update Model

### 8.1 Default: SSA In-Place

Resources keep stable, human-readable names. Server-Side Apply patches them in place. When content changes, the Nix store path changes, which means the identity-hash changes. The local DAG diff (§3.5) detects this by matching on Kubernetes identity (`kind + namespace + name`) and seeing a different identity-hash, triggering a re-apply.

This matches standard Kubernetes conventions. Rolling updates, HPA, PDB, and other K8s machinery work as expected.

### 8.2 Future: Content-Addressed Names (Blue-Green)

In the future, resource names may include a content hash suffix. A config change produces a *new* resource alongside the old one. The deploy engine creates the new resource, waits for it to be healthy, then prunes the old one. Every update is a zero-downtime blue-green deploy.

This requires reimplementing several K8s deployment strategies (rolling updates become prune-after-healthy, Services need selector updates, etc.). It is a significant design effort tracked separately.

### 8.3 Hybrid: Opt-In Blue-Green

Packages can opt into blue-green via `meta.updateStrategy = "blue-green"`. The default remains SSA in-place. The wave engine handles both: in-place resources are applied normally, blue-green resources follow the create → healthy → prune cycle.

---

## 9. Failure Modes & Recovery

### 9.1 Build Failure

`nix build` fails → no store graph → no deploy. Clean failure, nothing changes on the cluster.

### 9.2 Partial Apply (Mid-Wave Failure)

A resource in wave N fails to apply. Depending on `--on-error`:
- **stop** (default): Halt immediately. Waves 0..N-1 are fully applied and healthy. Wave N is partially applied. The Activation is NOT updated (the old one remains Active). Next deploy will re-attempt from the beginning.
- **continue**: Log the error, proceed. The Activation is updated only if the overall deploy succeeds (no errors in any wave). Allows partial progress at the cost of potentially inconsistent state.

**Recovery:** Re-run `kix deploy`. The local DAG diff will detect which resources still need to be applied (different identity-hash or absent) and retry them.

### 9.3 Readiness Timeout

A resource is applied but never becomes ready. The wave engine blocks. After timeout:
- **stop**: Halt. The resource exists but isn't ready. Manual investigation needed.
- **continue**: Proceed to next wave. Dependents may fail if they need the unhealthy resource.

**Recovery:** Fix the underlying issue (bad image, resource limits, etc.), re-deploy. Or `kix rollback` to the previous Activation.

### 9.4 CRD Race

CRDs need time to register with the API server. The deploy engine re-discovers API resources after any wave that creates CRDs. If a CR is applied before its CRD is registered, the API server returns "the server could not find the requested resource." The re-discovery step prevents this for correctly ordered waves. If it still occurs (e.g., CRD and CR in the same wave due to missing dependency), the error surfaces as a wave failure.

### 9.5 GC Deletes Something It Shouldn't

Hard GC deletes anything kix-labeled that's not in the expected set. If a resource was manually created with a kix label, hard GC will delete it.

**Mitigation:** GC always shows a plan and requires `--yes`. Never auto-GC without confirmation.

**Escape hatch:** `kix.dev/unmanaged: "true"` annotation excludes a resource from GC consideration.

### 9.6 Store Path Not in Local Nix Store

Soft GC and rollback depend on the old activation's store path being in the local Nix store. The identity-hash on the Activation CR resolves to a Nix store path (`/nix/store/<identity-hash>-...`). If `nix-collect-garbage` has run, the old store paths are gone.

**Mitigation:** If the local path is gone, fall back to:
1. `nix build .#cluster-<name>-activation` to rebuild (if inputs haven't changed)
2. Hard GC as a last resort

**Future:** Push activation store paths to a Nix binary cache or OCI registry for durable storage.

---

## 10. Open Design Work

### 10.1 Activation Naming & History

Current: one Activation per cluster name, updated in place. Proposed: `<cluster>-<generation>` naming with multiple Activations kept as history. Questions:
- What's the generation source? Monotonic counter on the Activation status? Git commit count?
- How many Superseded Activations to keep? Fixed window (e.g., 10)? TTL? Manual cleanup only?
- Should Superseded Activations have a finalizer that triggers GC before deletion?

### 10.2 Multi-Cluster GC

Addressed by the `kix.dev/activations` annotation (§5.4) and hard GC scoping by `kix.dev/cluster` label. Resources shared across activations are reference-counted — GC only deletes when no active activation claims the resource.

### 10.3 Reconciliation Loop

The deploy engine is currently one-shot. For continuous reconciliation:
- **Watch mode:** `kix deploy --watch` re-evaluates on a timer or inotify trigger
- **Operator mode:** A kix-operator pod runs the loop in-cluster
- **CI mode:** `kix deploy` runs on every git push

The pipeline is the same in all cases. The difference is the trigger and where it runs. Watch mode is the MVP.

### 10.4 Non-K8s Side Effects

The DAG can model imperative actions (DNS records, external users, cloud resources) as "task" nodes alongside manifest nodes. The wave engine already supports heterogeneous node types conceptually — it just needs a different apply path for non-K8s nodes. This is future work but the architecture should not preclude it.

### 10.5 Drift Detection vs. Self-Healing

Drift detection (reporting) and self-healing (reverting) are the same loop with different actions. Drift detection requires content-hash normalization against live cluster state (§6 — to be designed separately). The apply path is the healing mechanism. The reconciliation loop (§10.3) ties them together. No separate drift detection system needed — but the normalization pipeline is a prerequisite.
