# Dependency Tracking V2: Research Findings and Revised Design

This document supersedes the typed-refs proposal in `DEPENDENCY_TRACKING.md` based on
deeper analysis of the Nix module system fixpoint semantics, functional architecture
tradeoffs, and K8s operational constraints.

## Luca's Feedback on V1

The typed-refs (`ref`) approach had a **major flaw**:

> "This embeds the object, but assumes the object does not change anymore.
> This forces evaluation to be linear instead of functional."
>
> "If you want prometheus to affect coredns — `ref prometheus`. Then some other
> requirement (e.g., customer override) needs to change prometheus. The ref is
> not updated since it was a copy of the original attrset and is never reevaluated."

Additional corrections:
- **Store paths ARE valid K8s names.** The V1 doc's claim that they're "illegal" was wrong.
  Luca tested it. Format: `hash-human-readable-name`.
- **Original kix's `mkManifest` was an explicit conversion point** — you knew in the code
  when you lost dynamicness. The `ref` approach hides this.
- **References only needed the hashed store path**, not a full copy of the manifest.

## The Snapshot Problem — When It's Real

The Nix module system computes a **fixpoint** via `lib.evalModules`. All `config.*` values
are part of one lazy attrset that only evaluates when forced. This means:

**Through `config.*` — NO snapshot problem:**
```nix
# This always sees the final merged value, even if another module overrides it
config.manifests.coredns-crb = {
  roleRef.name = config.manifests.coredns-clusterrole.metadata.name;
};
```

**Via let-binding — snapshot problem EXISTS:**
```nix
let
  clusterRole = kixlib'.mkClusterRole { ... };
in {
  config.manifests.coredns-crb = {
    roleRef.name = clusterRole.metadata.name;  # captures the local value
  };
}
# If another module overrides config.manifests.coredns-clusterrole,
# this ref still sees the original let-bound value
```

**Why this is mostly academic for kixpkgs:** Within a single chart module, let-bindings
are safe — they're in the same authorial scope, no override can interpose. The snapshot
problem only matters for **cross-module references**, which should go through `config.*`.
This is the same discipline NixOS follows: the source of truth is always `config`, never
a local binding, for anything another module might override.

## Why Store Paths Are Not the Answer (Despite Being Valid)

Luca is right that store paths work as K8s names. But analysis reveals serious operational
problems:

**Service DNS instability.** K8s Service names become DNS names
(`<name>.<namespace>.svc.cluster.local`). Other pods, ingress rules, network policies,
and external systems all reference these. A content-addressed name means **every content
change cascades into a rename** across all consumers. Service names are effectively a
stable API contract — content-addressing breaks this.

**Monitoring discontinuity.** Prometheus metric labels include resource names. When the
hash changes on deploy, Grafana dashboards show gaps, alert history resets, and you lose
the ability to correlate metrics across deploys.

**RFC 1035 compliance.** Services and Namespaces require names starting with a letter
(RFC 1035 DNS labels). Store hashes use nix-base32 which includes digits 0-9 — roughly
20% of hashes start with a digit, making them invalid for these resource types.

**Operational friction.** `kubectl logs deploy/cert-manager` works from memory.
`kubectl logs deploy/rvhqgspmkz4bghxlncjhig1dg1a1fmwn-cert-manager` requires discovering
the name first via `kubectl get`. This friction multiplies across every debugging session.

**Recommendation:** Human-readable names in `metadata.name`. Store hash in an annotation
or label if content-addressability is needed for specific use cases.

## Options Evaluated

### Option A: Typed Refs (`ref` wrapper) — REJECTED

```nix
ref = resource: { _ref = resource; };
roleRef.name = ref clusterRole;  # carries the object
```

- Single source of truth (ref IS the dep)
- But: **snapshot problem** — embeds the object at ref-creation time
- Forces linear evaluation order — anti-functional
- Reimplements Nix's DAG tracking in userland (~30 lines to approximate what Nix gives
  for free with derivations)
- Every consumer of manifests must handle `{ _ref = ... }` wrappers

### Option B: `_deps` Metadata — REJECTED

```nix
roleRef.name = clusterRole.metadata.name;
_deps = [ clusterRole ];
```

- Same snapshot problem as Option A
- PLUS redundant bookkeeping — two sources of truth that can diverge silently
- Someone writes correct YAML but forgets `_deps` — graph is wrong, no error

### Option C: Derivation-Based Refs (Original Kix) — NOT SUITABLE

```nix
roleRef.name = self.mkManifest clusterRole;  # store path IS the reference
```

- Functionally superior — content-addressed, automatic change propagation
- Explicit phase boundary (`mkManifest` = you know when you lose dynamicness)
- But: conflicts with kixpkgs' deferred serialization architecture. kixpkgs deliberately
  keeps resources as raw attrsets in `config.manifests` throughout the entire module
  evaluation. This means expressions like `config.manifests."coredns-deployment".spec.selector`
  and `config.manifests."cert-manager-sa".metadata.labels` are valid — you can reach into
  any resource's fields through the fixpoint. Cross-resource validation (`validateManifestSet`),
  cross-cutting modules (monitoring reads `config.manifests.*.metadata.labels`), and user
  overrides all depend on this. If `mkManifest` converts resources to derivations early
  (as original kix did), `config.manifests."coredns-deployment"` becomes an opaque store
  path — you can't do `.spec.selector` on `/nix/store/abc123-coredns.yaml`. Validation
  would require deserializing YAML back to attrsets, defeating the purpose. The entire
  module system's composability depends on resources staying as attrsets until the output
  boundary.
- Store path naming has operational problems (see above)

### Option D: Kind-Based Static Ordering — INSUFFICIENT

```nix
applyOrder = { Namespace = 0; ServiceAccount = 10; ClusterRole = 20; Deployment = 40; };
```

- Zero builder changes, covers 95% of apply ordering
- But: no real graph, can't answer "what depends on what?"
- Not a foundation for cluster-level dependency management

### Option E: Structural Inference — CHOSEN

Infer dependencies from the final, fully-merged manifest set. Don't track them at
construction time at all.

```
Snapshot-safe?              YES — runs on final fixpoint data
Single source of truth?     YES — derived from the K8s fields themselves
Module-system compatible?   YES — runs after the fixpoint settles
Human-readable names?       YES — no naming changes needed
Builder changes?            NONE — inference is a separate pass
```

## Chosen Approach: Structural Inference

### Core Idea

Dependencies are a **derived property** of the manifest data, not metadata bolted on at
construction time. A function walks the final manifest set — after the module fixpoint has
settled, after all overrides are applied — and extracts edges from well-known K8s reference
fields.

This is the same approach a compiler uses to infer variable dependencies from usage rather
than requiring explicit `depends-on` annotations.

### Why This Fits kixpkgs

kixpkgs' key architectural decision is **deferred serialization**: `config.manifests` stores
raw attrsets, not derivations. Serialization happens at the output boundary in `mkManifests`.
This means:

1. The module fixpoint runs on raw attrsets — overrides, merges, cross-cutting modules all work
2. `validateManifestSet` already walks the final data for referential integrity
3. Dependency inference is a natural extension of this existing infrastructure

Structural inference **follows from** the deferred serialization choice rather than fighting
against it.

### The Reference Fields

K8s has a finite, well-documented set of cross-resource reference patterns:

| Source Kind | Field | Target Kind |
|---|---|---|
| Deployment, StatefulSet, DaemonSet, Job | `spec.template.spec.serviceAccountName` | ServiceAccount |
| RoleBinding, ClusterRoleBinding | `roleRef.kind` + `roleRef.name` | Role, ClusterRole |
| RoleBinding, ClusterRoleBinding | `subjects[].name` | ServiceAccount |
| Deployment, StatefulSet, etc. | `spec.template.spec.volumes[].configMap.name` | ConfigMap |
| Deployment, StatefulSet, etc. | `spec.template.spec.volumes[].secret.secretName` | Secret |
| Service | `spec.selector` (label match) | Workload pod templates |
| HorizontalPodAutoscaler | `spec.scaleTargetRef.kind` + `spec.scaleTargetRef.name` | Workload |
| MutatingWebhookConfiguration | `webhooks[].clientConfig.service.name` | Service |
| ValidatingWebhookConfiguration | `webhooks[].clientConfig.service.name` | Service |
| Ingress | `spec.rules[].http.paths[].backend.service.name` | Service |

This list is finite and grows slowly. Adding a new reference pattern is a one-line
extractor addition, not a builder-level change.

### Implementation Sketch

```nix
# Extend kixlib or flake.nix — runs on the final manifest set

inferDependencies = manifests:
  let
    resources = lib.attrValues manifests;

    # Index for O(1) lookup
    byKindName = builtins.foldl' (acc: r:
      acc // { "${r.kind}:${r.metadata.name}" = r; }
    ) {} resources;

    hasResource = kind: name: byKindName ? "${kind}:${name}";

    # Reference extractors — each returns a list of { kind, name } edges
    workloadKinds = [ "Deployment" "StatefulSet" "DaemonSet" "Job" "CronJob" ];
    workloads = builtins.filter (r: builtins.elem r.kind workloadKinds) resources;

    getPodSpec = r: r.spec.template.spec or {};

    extractors = r:
      # Workload → ServiceAccount
      (if builtins.elem r.kind workloadKinds then
        let sa = (getPodSpec r).serviceAccountName or null;
        in if sa != null then [{ kind = "ServiceAccount"; name = sa; }] else []
      else [])
      ++
      # RoleBinding → Role/ClusterRole + ServiceAccount subjects
      (if builtins.elem r.kind [ "RoleBinding" "ClusterRoleBinding" ] then
        let ref = r.roleRef or {};
        in [{ kind = ref.kind or ""; name = ref.name or ""; }]
           ++ builtins.concatMap (s:
             if s.kind or "" == "ServiceAccount"
             then [{ kind = "ServiceAccount"; name = s.name; }]
             else []
           ) (r.subjects or [])
      else [])
      ++
      # Workload → ConfigMap volumes
      (if builtins.elem r.kind workloadKinds then
        builtins.concatMap (vol:
          let cm = (vol.configMap or {}).name or null;
          in if cm != null then [{ kind = "ConfigMap"; name = cm; }] else []
        ) ((getPodSpec r).volumes or [])
      else [])
      ++
      # Workload → Secret volumes
      (if builtins.elem r.kind workloadKinds then
        builtins.concatMap (vol:
          let sec = (vol.secret or {}).secretName or null;
          in if sec != null then [{ kind = "Secret"; name = sec; }] else []
        ) ((getPodSpec r).volumes or [])
      else [])
      ++
      # HPA → Workload
      (if r.kind == "HorizontalPodAutoscaler" then
        let ref = r.spec.scaleTargetRef or {};
        in [{ kind = ref.kind or ""; name = ref.name or ""; }]
      else []);

    # Build the graph: manifest key → list of dependency edges
    graph = lib.mapAttrs (key: resource: {
      inherit (resource) kind;
      name = resource.metadata.name;
      dependsOn =
        let
          edges = extractors resource;
          # Only include edges that resolve to resources in our set
          resolved = builtins.filter (e: hasResource e.kind e.name) edges;
        in resolved;
    }) manifests;

  in graph;
```

### Relationship to `validateManifestSet`

`validateManifestSet` already walks these same reference patterns for validation. With
structural inference:

1. **Extract** the dependency graph (the code above)
2. **Validate** by checking all edges resolve (replaces the ad-hoc checks in `validateManifestSet`)
3. **Order** via topological sort for apply sequencing
4. **Introspect** — "what depends on X?" queries for impact analysis

All four operations derive from the same graph. `validateManifestSet` becomes a thin wrapper
around `inferDependencies` instead of a separate, parallel implementation.

### Topological Sort for Apply Ordering

```nix
# Given the dependency graph, produce a list of manifest keys in apply order
topoSort = graph:
  let
    # Standard Kahn's algorithm or DFS-based toposort
    # Resources with no dependencies come first
    # ...
  in sortedKeys;
```

Combined with a **kind-based tiebreaker** for resources at the same topological level
(Namespaces before Services before Deployments), this gives correct apply ordering that
handles both structural deps and conventional K8s ordering.

### Service Selector Matching

Service → Workload is a special case: it's a label match, not a name reference. The
inference handles this by matching `spec.selector` against pod template labels:

```nix
# Service → Workload (label selector match)
(if r.kind == "Service" then
  let
    selector = r.spec.selector or {};
    matchingWorkloads = builtins.filter (w:
      let templateLabels = w.spec.template.metadata.labels or {};
      in builtins.all (k:
        (templateLabels.${k} or null) == selector.${k}
      ) (lib.attrNames selector)
    ) workloads;
  in map (w: { kind = w.kind; name = w.metadata.name; }) matchingWorkloads
else [])
```

### Explicit Dependencies for Non-Inferable Edges

Some dependencies can't be inferred from K8s fields (e.g., "this Job should run after
this Deployment is healthy"). For these, an annotation-based escape hatch:

```nix
# Optional: explicit dependency annotation for edges that can't be inferred
metadata.annotations."kix.dev/depends-on" = "Deployment/cert-manager";
```

This is opt-in, not the primary mechanism. The structural inference handles the common
cases; the annotation handles the exceptions.

## Cross-Chart References

For references between charts (e.g., coredns referencing a prometheus endpoint), use the
module fixpoint — read from `config.*`:

```nix
# Chart B references chart A's resource through the fixpoint
{ config, ... }:
{
  # This sees the final merged value — no snapshot problem
  roleRef.name = config.manifests."chart-a-clusterrole".metadata.name;
}
```

The service registry (`modules/registry.nix`) already provides this for endpoint discovery.
Structural inference picks up the resulting name references automatically.

## Comparison to Original Kix

| Aspect | Original Kix | kixpkgs V2 (Structural Inference) |
|---|---|---|
| **Phase boundary** | Per-resource (`mkManifest`) | Output edge (`mkManifests`) |
| **When you lose dynamicness** | Explicit — call `mkManifest` | Implicit — at serialization |
| **Dependency tracking** | Free via Nix DAG | Inferred from final data |
| **Naming** | Store path hash + human name | Human-readable only |
| **Override composability** | Limited (post-`mkManifest` is frozen) | Full (attrsets through entire pipeline) |
| **Cross-resource validation** | Not available (derivations are opaque) | Full (`validateManifestSet`) |

Original kix's derivation approach was the right design for per-resource serialization.
kixpkgs made a different choice (deferred serialization) that enables richer composition
and validation. Structural inference is the dependency tracking mechanism that follows
naturally from that choice.

## Implementation Plan

### Phase 1: `inferDependencies` function
Add to `lib/default.nix` or `flake.nix`. Pure Nix function that takes the manifest attrset
and returns a dependency graph. Cover: SA refs, roleRef, configMap/secret volumes, HPA
targets, service selectors.

### Phase 2: Unify with `validateManifestSet`
Rewrite `validateManifestSet` to use `inferDependencies` internally. Same validations,
but derived from the graph instead of ad-hoc walks.

### Phase 3: Topological sort
Add `topoSort` that produces apply ordering from the graph. Combine with kind-based
tiebreaker for same-level resources.

### Phase 4: Expose in output
Add a `dependency-graph.yaml` or similar to the build output so the graph is inspectable.
Consider a `--apply-order` flag that outputs manifests in sorted order.

### Phase 5: Webhook and admission dependencies
Extend extractors for MutatingWebhookConfiguration, ValidatingWebhookConfiguration,
and Ingress backend references.

## Open Questions

- **Should the graph be part of `config.*`?** E.g., `config.dependencyGraph` computed
  lazily from `config.manifests`. This would let modules react to the graph (e.g., a
  module that adds `kix.dev/depends-on` annotations to all manifests).

- **Cycle detection.** K8s doesn't have circular dependencies, but the inference might
  find apparent cycles (e.g., Service → Deployment → ConfigMap → ... → Service via
  indirect label matching). How to handle?

- **External references.** When a workload references a ServiceAccount that's not in
  our manifest set (e.g., the `default` SA, or `system:` ClusterRoles), the edge
  should be recorded but not validated. The current `validateManifestSet` already
  handles this with allowlists.
