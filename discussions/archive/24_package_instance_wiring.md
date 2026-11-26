# PackageInstance Wiring — Top-Down Overlay Design

**Status:** Accepted design
**Supersedes:** Parts of `10_merkle_dag_package_instance.md` (PI role in the DAG)
**Files:** `lib/k8s.nix`, `lib/eval.nix`

---

## Problem

The PackageInstance (PI) CR carries important package-level metadata (main resource, inverse deps, package requires, version). However, it is not on the critical path of cross-package dependencies. When package A depends on package B's Service, the store DAG edge goes directly from A's Deployment to B's Service — the PI is bypassed entirely.

This raises two questions:
1. **How should PI be wired into the Merkle DAG?**
2. **How do we answer "which package owns this resource?" and "what resources belong to this package?"**

We evaluated four approaches (re-stamping `out` with PI context, dual context, full-closure PI, PI-as-scope). The chosen design is the **top-down overlay**: PI looks down at resources, resources are unaware of PI, and navigability questions are answered via labels and the evaluation-time registry.

## Design

### The three edge types

The store DAG contains exactly three types of edges. No mixing.

1. **PI → resources** (downward): PI annotations reference main resource, inverse deps, and package requires. These strings carry store context, creating store DAG edges from PI into the package's resource subgraph.

2. **Activation → PIs** (top-level): The Activation resource's `spec.instances` references all PI `out.name` values, which carry PI store context. This is the entry point for package-level traversal.

3. **Resource → resource** (peer, cross-package): When package A uses `B.out.fqdn` in a manifest, the string carries B's main resource's store context. The edge goes directly from A's resource to B's resource. No PI in the path.

```
Activation ──→ PI(immich) ──→ Service(immich)     [main annotation]
             → PI(valkey) ──→ Service(valkey)      [main annotation]
                            → ServiceMonitor(valkey) [inverseDep annotation]

Cross-package (direct, no PI):
  Deployment(immich) → Service(valkey)   [via out.fqdn string context]
```

### Hash propagation

This design gives maximally tight cross-package hash propagation:

- **ServiceMonitor(valkey) changes** → Service(valkey) unchanged (no edge) → Deployment(immich) unchanged. Correct.
- **Service(valkey) changes** → Deployment(immich) hash changes (direct edge). Correct.
- **PI(valkey) metadata changes** (e.g., inverseDeps list changes) → only Activation hash changes. No consumer resources are affected.

A consumer's hash changes **only** when the specific resource it depends on changes, not when unrelated resources in the dependency package change.

### `out` values carry resource context, not PI context

`instance.out` values (name, fqdn, selector, etc.) carry the **main resource's** store context. This is intentional — it gives consumers a direct dependency edge to the resource they actually use, preserving fine-grained hash propagation.

```nix
# In evaluateInstance:
out = (mainRes.out or {}) // packageOut;
# mainRes.out.fqdn carries Service(valkey) store context
# NOT PI(valkey) store context
```

## Invariants

### 1. No resource shall depend on a PI

A resource's store hash must never include a PI's store path in its context. If a resource depended on a PI, then PI metadata changes (version annotation, inverseDeps list) would cascade to the resource's hash and transitively to all consumers. This violates tight hash propagation.

**Enforcement:** PI is created after all resources are evaluated (in `evaluateInstance`). Resources cannot reference something that doesn't exist yet. The scope object does not expose PI.

### 2. Cross-package edges go resource → resource, never through PI

When package A uses `B.out.fqdn`, the store context points to B's main resource, not B's PI. This is a direct consequence of invariant 1 and of `out` carrying resource context.

### 3. PI references resources via annotation string context

PI's annotations (`kix.dev/main`, `kix.dev/inverse-deps`, `kix.dev/package-requires`) contain strings that carry store context of the referenced resources. This creates PI → resource edges in the store DAG. These are the only edges FROM a PI to resources.

### 4. PI's store closure covers all non-orphaned package resources

PI → main resource (annotation context) → transitive closure covers forward deps. PI → inverseDeps (annotation context) covers inverse deps. PI → packageRequires (annotation context) covers structural deps. With `requires` now creating store DAG edges (see "Bug fix" below), the transitive closure from PI reaches all resources that are reachable from main + inverseDeps + packageRequires. Resources not reachable from any of these are orphaned (and already trigger a warning).

### 5. Activation is the sole top-level entry to the PI layer

Only Activation references PIs. No other resource or evaluation output references a PI's store path. The PI layer is a metadata overlay reachable only from the top.

## Navigability

### Q1: "Which package does this resource belong to?"

**Primary mechanism: labels.** Every resource created via `scope.mkResource` gets instance labels (`app.kubernetes.io/instance`, `app.kubernetes.io/managed-by`). Reading the label answers Q1 in O(1) with no DAG traversal.

**DAG verification (optional):** From Activation, enumerate PIs. For each PI, walk its store closure. If the target resource appears in a PI's closure, that PI's instance name matches the label. This is O(total resources) to build a full index but is only needed for verification or debugging.

### Q2: "What resources belong to this package?"

**Primary mechanism: evaluation-time registry.** `collectResources` in `buildCluster` already groups resources by instance. This grouping is the authoritative answer. The pipeline reads it directly from the evaluation output — no DAG walk needed.

**DAG walk (for tooling/debugging):** Walk PI's store closure. This includes own resources AND dependency resources (because cross-package edges go resource → resource). To isolate own resources, filter by instance labels or subtract dependency PI closures.

### Q3: "Which packages does this package depend on?"

Walk PI's store closure. Identify store paths that belong to other packages (via label or registry lookup). Map them to their PIs. This gives the transitive package dependency graph.

Alternatively, the pipeline can build this from cross-package store context edges detected during resource collection.

## Runtime metadata via kix-deploy

The PI CR is a compile-time artifact — its store hash tracks structural dependencies. Runtime-relevant metadata that does NOT affect dependency ordering (human-readable version strings, deploy timestamps, git SHAs) should be added by `kix-deploy` as **annotations on the deployed PI manifest**, not by the Nix evaluator.

This separation ensures:
- **Compiler (Nix):** PI hash is stable. Metadata-only changes don't trigger rebuilds or cascade to consumers.
- **Tooling (kix-deploy, dashboards):** The deployed PI CR carries rich runtime context (version, deploy time, git ref) for observability and debugging.

Example annotations added at deploy time:
```yaml
metadata:
  annotations:
    kix.dev/version: "1.2.3"
    kix.dev/deployed-at: "2026-03-24T15:30:00Z"
    kix.dev/git-sha: "abc123"
    kix.dev/deployed-by: "ci/cd-pipeline"
```

These annotations are purely cosmetic — they do not exist in the Nix store and do not affect any hash computation.

## Bug fix: `requires` creates store DAG edges (two-phase identity)

The `requires` field creates real Nix store DAG edges at the individual resource level. Each resource has a **two-phase identity** to avoid infinite recursion when `requires` edges oppose manifest-context edges in the same fixpoint:

- **Phase 1 (`_contentPath`):** store path from manifest content only. `out` values carry this context. Consumers that use `dep.out.name` get a dependency on `_contentPath`.
- **Phase 2 (`_identityPath`):** wraps `_contentPath` + store contexts from all `requires`/`extraDeps`. This is the resource's `outPath`. If no structural deps exist, `_identityPath = _contentPath` (zero overhead).

The cycle breaks because manifest-direction dependencies resolve at phase 1, while requires-direction dependencies resolve at phase 2. Phase 1 never depends on phase 2.

```nix
_contentPath = builtins.toFile "k8s-${kind}-${nsKey}-${sanitizedName}" manifestJson;

depContexts = builtins.foldl' (acc: dep:
  if builtins.isAttrs dep && dep ? outPath then
    acc // builtins.getContext "${dep}"
  else acc
) {} (requires ++ extraDeps);

_identityPath =
  if allDeps == [] then _contentPath
  else builtins.toFile "k8s-dep-${kind}-${nsKey}-${sanitizedName}"
    (builtins.appendContext "${_contentPath}" depContexts);
```

The registry maps both paths to the resource. `forwardPaths` and `reachablePaths` in `evaluateInstance` include both paths for correct inverse-dep detection.

The PI's `requires` includes `[ mainResource ] ++ inverseDeps ++ packageRequires`, ensuring its `_identityPath` transitively covers the full package closure including all structural deps.

```
Deployment(immich) → Service(valkey)._contentPath [manifest context, phase 1]
Service(valkey)._identityPath → StatefulSet(valkey)._identityPath [requires, phase 2]
PI(valkey)._identityPath → Service(valkey)._identityPath [PI requires, phase 2]
```

## Rejected alternatives

### Re-stamp `out` with PI context (Option A from discussion)

Replace resource context on `out` values with PI context, putting PI on every cross-package path.

**Rejected because:** Over-propagates. If PI(valkey) hash changes (e.g., inverseDeps list changes), every consumer of valkey sees a hash change even though the Service they depend on didn't change. Also, if PI depends on the full package closure, any internal change (ConfigMap tuning) propagates to all consumers.

### Dual context (Option B)

Append PI context alongside resource context on `out` values.

**Rejected because:** Same over-propagation as Option A (consumer hash depends on PI hash). Also adds complexity — double edges on every cross-package reference require pipeline scripts to categorize edges as PI-edges vs resource-edges.

### Full-closure PI (Option C)

Make PI `requires` all forward closure resources directly.

**Rejected because:** PI's hash would depend on ALL resources. Any change in the package (even to an unrelated ConfigMap) changes PI's hash. Combined with Option A or B, this cascades to all consumers. Also largely redundant — PI's transitive closure already covers all non-orphaned resources via the main → forward closure chain.

### PI as scope object (Approach 2)

Create PI before resources, inject it into scope like Namespace. All resources depend on PI.

**Rejected because:** Violates invariant 1 (no resource depends on PI). PI metadata changes would cascade to all package resources and transitively to all consumers. Also, PI cannot contain resource references (created before resources exist), so it loses the "package manifest" semantics. Bidirectional PI ↔ resource edges are fundamentally impossible in an acyclic store DAG.

## Relation to existing design

This document clarifies and refines the PI design from `10_merkle_dag_package_instance.md`. The core implementation is unchanged — PI is created in `evaluateInstance`, references main/inverseDeps/packageRequires via annotations, and is collected alongside resources.

The key clarification is that PI being bypassed on cross-package paths is **by design**, not a bug. The tight hash propagation this enables is more valuable than having PI on every dependency path. Navigability is handled by labels and the evaluation-time registry, not by store DAG structure.

The `requires` bug fix (store DAG edges for structural deps) ensures the Merkle DAG is complete without needing PI to be an intermediary.
