# Dependency Tracking V3: The Real Tradeoff

Supersedes V1 (typed refs) and refines V2 (structural inference) with a critical
finding: deferred serialization was a kixpkgs design choice, not an inherent requirement.

## The Core Discovery

Original kix stored **derivations** in `config.manifests`:

```nix
# kix: corednsNew/default.nix
manifests = lib.optionalAttrs coredns.enable {
  "coredns" = kixlib'.mkManifest cService;  # derivation, not attrset
};

# kix: flake.nix — Nix's built-in DAG extraction
exportReferencesGraph = lib.concatLists (
  lib.mapAttrsToList (name: path: [ "graph-${name}" path ])
    evaluation.config.manifests
);
```

kixpkgs stores **attrsets** in `config.manifests`. This was a design choice made during
kixpkgs development to enable features that original kix didn't have:

- `validateManifestSet` — cross-resource validation by walking attrset fields
- Cross-cutting monitoring module reading `config.manifests.*.metadata.labels`
- User overrides via `lib.mkForce` on individual resource fields
- Service registry deriving endpoints from resource metadata

**None of these existed in original kix.** They emerged during kixpkgs development.
The question is: are they worth the loss of native dependency tracking?

## The Real Tradeoff

| | Original Kix (derivations) | kixpkgs (attrsets) |
|---|---|---|
| `config.manifests.*` contains | Store paths (opaque) | Attrsets (inspectable) |
| Dependency tracking | Free via Nix DAG + `exportReferencesGraph` | Lost — must be recovered |
| Cross-resource validation | Not possible (derivations are opaque) | Full (`validateManifestSet`) |
| Cross-cutting modules | Can't read resource fields | Can read `config.manifests.*.spec.*` |
| User overrides of fields | Not possible (derivation is frozen) | Works via `lib.mkForce` |
| Phase boundary | Explicit per-resource (`mkManifest`) | Implicit at output edge (`mkManifests`) |

## What kixpkgs Gained from Attrsets

### 1. Cross-resource validation (`validateManifestSet`)
Walks the final manifest set at eval time. Checks that ServiceAccount references resolve,
RoleBindings point to existing Roles, Service selectors match workload labels, ConfigMap
volume refs exist, HPA targets exist. Pure Nix, no IFD.

### 2. Cross-cutting modules
The monitoring module reads `config.manifests.*.metadata.labels` to generate ServiceMonitors.
Network policy module could read `config.manifests.*.spec.selector` to auto-generate policies.
This requires attrsets — you can't do `.metadata.labels` on a store path.

### 3. User overrides
A cluster definition can do:
```nix
config.manifests."valkey-primary".spec.replicas = lib.mkForce 3;
```
This works because the resource is an attrset in the fixpoint. With derivations, you'd
need to override the input options (e.g., `services.valkey.replicaCount`) instead.

### 4. Service registry
`modules/registry.nix` — charts declare endpoints derived from their resource metadata.
Other charts discover services through `config.registry.*`. This reads resource fields.

## What kixpkgs Lost

### Native dependency tracking
Nix's DAG tracking works because **derivations reference other derivations via store paths
in build inputs**. When you interpolate `${packageA}` into packageB's build script, Nix
sees the store path and records the edge automatically.

With attrsets, the module fixpoint resolves all `config.*` references to final string values.
`config.manifests."coredns-configmap".data.upstream` becomes `"valkey-primary.default.svc.cluster.local"`.
The provenance — that this string came from valkey — is **erased by evaluation**. Nix has
no record of the connection.

### Explicit phase boundary
Original kix's `mkManifest` was a visible conversion point: attrset → derivation. You knew
when you lost dynamicness. kixpkgs serializes everything at the output edge, which is
convenient but invisible.

## Approaches Evaluated (with Expert Agent Research)

### Typed refs (`ref` wrapper) — V1 proposal, REJECTED
```nix
ref = resource: { _ref = resource; };
roleRef.name = ref clusterRole;
```
**Flaw (identified by Luca):** Embeds a snapshot of the object. If the referenced resource
is later modified by another module or user override, the ref is stale. Forces linear
evaluation — anti-functional. Reimplements Nix's DAG tracking in userland.

### `_deps` metadata — REJECTED
```nix
_deps = [ clusterRole serviceAccount ];
```
Same snapshot problem as typed refs, plus redundant bookkeeping (two sources of truth).

### Derivation-based refs with human names — INVESTIGATED, NOT FEASIBLE
The idea: keep attrsets in `config.manifests` but compute parallel "shadow derivations"
for DAG tracking, with store hashes as annotations.

**Findings from expert agents:**
- Computing a content hash or derivation from a resource that participates in the fixpoint
  risks **infinite recursion** — `builtins.toJSON` forces deep evaluation, which can trigger
  circular fixpoint evaluation if resources reference each other through `config.*`
- Shadow derivations don't create DAG edges from content — `builtins.toJSON` resolves
  everything to strings, erasing which values came from where
- The Nix store DAG is the wrong abstraction for eval-time graph analysis
- **Content hashes at the output boundary** (post-fixpoint) DO work — useful for drift
  detection and garbage collection, but no dependency edges

### Store paths as K8s resource names — REVISITED, OPERATIONAL PROBLEMS
Luca confirmed store paths ARE valid K8s names (contrary to V1 doc's claim). However:
- **Service DNS instability** — hash changes on every content change, breaking all consumers.
  Service names are effectively a stable API contract.
- **Monitoring discontinuity** — Prometheus metric labels change, dashboards show gaps
- **RFC 1035** — Services/Namespaces require names starting with a letter; ~20% of store
  hashes start with a digit
- **Operational friction** — can't type names from memory during incidents

### Structural inference — V2 proposal, STILL VALID
Infer dependencies from the final manifest set by walking well-known K8s reference fields.
**Limitation (identified by Luca):** brittle for CRDs, custom references, and relationships
that can't be inferred from K8s field patterns.

## Current Best Understanding

### Layered approach

**Layer 1: Structural inference (automatic, covers K8s core)**
Walk the final manifest set after the fixpoint settles. Extract edges from well-known
reference fields (serviceAccountName, roleRef, configMap volumes, service selectors, etc.).
This is an extension of `validateManifestSet` which already does this for validation.

**Layer 2: Explicit `_dependsOn` (opt-in, covers everything else)**
For dependencies that inference can't find (CRDs, operational ordering, domain-specific):
```nix
config.manifests."my-certificate" = myCert // {
  _dependsOn = [
    config.manifests."cert-manager-deployment"  # through fixpoint, no snapshot
  ];
};
```
Goes through `config.*` fixpoint — no snapshot problem. `_`-prefixed, stripped at
serialization. Optional — charts that don't need it don't use it.

**Layer 3: Content hash annotation (operational tooling)**
Computed at the output boundary after the fixpoint:
```nix
withHashes = lib.mapAttrs (name: resource:
  resource // {
    metadata.annotations."kix.dev/content-hash" =
      builtins.hashString "sha256" (builtins.toJSON resource);
  }
) evaluation.config.manifests;
```
Enables stateless garbage collection and provenance tracking via a CLI tool.
No DAG edges, but practically useful.

**Kind-based tiebreaker for apply ordering:**
Static priority list (Namespace=0, SA=10, ClusterRole=20, Deployment=40, etc.)
for resources at the same topological level. Covers the 95% case cheaply.

## The Deeper Question: Do We Need Attrsets?

The features that require attrsets in `config.manifests`:
- `validateManifestSet` (cross-resource validation)
- Cross-cutting modules (monitoring, network policy)
- User overrides of individual resource fields
- Service registry

**Are these essential, or did they emerge from the LLM-driven development process?**
This needs honest evaluation. Original kix worked without them. The cross-cutting module
system is powerful but adds complexity. `validateManifestSet` catches real bugs but could
potentially work differently (e.g., validate before serialization using a different mechanism).

If we decided these features aren't worth the cost, we could go back to derivation-based
manifests and get native dependency tracking for free. But that's a fundamental architecture
decision, not a dependency-tracking decision.

## Do We Actually Need Cross-Resource Inspection?

Every use of cross-resource inspection in kixpkgs has an alternative that doesn't
require reading into `config.manifests.*`:

**Validation (`validateManifestSet`):** Reads `config.manifests.*.roleRef.name` to check
references resolve. But with derivation-based refs, Nix's DAG already guarantees the
reference exists — you can't reference a derivation that doesn't exist. Validation
becomes unnecessary because **correctness is structural**.

**Monitoring module:** Reads `config.manifests.*.metadata.labels` to generate ServiceMonitors.
But charts already declare `monitoring.targets.*` as a separate option. The monitoring
module reads THAT, not the raw resource fields. **It doesn't need to inspect resources.**

**User overrides:** `config.manifests."valkey-primary".spec.replicas = lib.mkForce 3`.
But you can also do `services.valkey.replicaCount = 3` — the option-level override.
**You don't need to reach into the resource if the option surface is good enough.**

**Service registry:** Already uses `config.registry.*` — charts declare endpoints as
options, consumers read options. No resource inspection needed.

The "higher level config everything draws on" already exists: **module options and the
registry.** Charts declare `services.<name>.*` options and `registry.<name>.endpoints.*`.
Other charts and modules read from those. Nobody needs to read raw K8s resource fields
if the option layer exposes the right information.

### The simpler architecture

```
Options (services.*, registry.*, monitoring.targets.*)
  ↓ charts read options, produce resources
Derivations in config.manifests (opaque, but with free DAG)
  ↓ exportReferencesGraph gives us the dependency graph
  ↓ mkManifests serializes at output
YAML files
```

Instead of the current:

```
Options (services.*, registry.*, monitoring.targets.*)
  ↓ charts read options, produce resources
Attrsets in config.manifests (inspectable, but no DAG)
  ↓ validateManifestSet reads into attrsets to recover correctness
  ↓ mkManifests serializes at output
YAML files
```

This might mean going back to derivation-based manifests — getting free dependency
tracking, free validation (Nix won't build if a reference is missing), and
`exportReferencesGraph` for the dependency graph. The cost is losing the ability to
reach into `config.manifests.*.spec.*`, which we might not actually need if the
option layer is complete.

## Open Questions for Next Session

1. **Are the attrset-dependent features (validation, cross-cutting modules, user overrides)
   genuinely valuable enough to justify losing native dependency tracking?** Or were they
   solutions looking for problems?

2. **Could we have a hybrid?** Attrsets during module evaluation (for composition), then
   convert to derivations at a well-defined point (for DAG tracking), with a way to
   extract the graph? The challenge is that the conversion point must be after the fixpoint
   but before the output boundary.

3. **Is `_dependsOn` through the fixpoint sufficient for the cluster-level dependency
   management use case Luca envisions?** Or does it need to be more structural?

4. **What does Luca actually want to DO with the dependency graph?** Apply ordering is
   one use case, but he said it's a "key future feature for cluster-level dependency
   management." What does that look like concretely?

## Key Files

- `DEPENDENCY_TRACKING.md` — V1 (typed refs, superseded)
- `DEPENDENCY_TRACKING_V2.md` — V2 (structural inference, refined here)
- `/Users/adam/Projects/kix/coredns/lib/default.nix` — original kix kixlib (derivation-based)
- `/Users/adam/Projects/kix/coredns/flake.nix:76` — `exportReferencesGraph` usage
- `/Users/adam/Projects/kix/simple-dependency/simple-dependency.nix` — DAG via buildInputs
- `lib/default.nix` — current kixpkgs kixlib (attrset-based)
- `flake.nix:341-494` — `validateManifestSet` (cross-resource validation)
