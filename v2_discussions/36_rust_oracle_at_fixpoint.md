# Rust Oracle at the Fixpoint

## Working Document — March 2026

**Status:** Design exploration
**Related:** `29_compiler-design.md` (compiler framing), `10_merkle_dag_package_instance.md` (DAG design), `cli/CLAUDE.md` (Rust CLI architecture)

---

## 1. Context

This document captures a design exploration around three connected questions:

1. What does it mean for kix to be a **compiler** rather than a smart templating engine?
2. What does the Nix store / Merkle DAG give us as a compiler foundation?
3. Where does Rust fit — not just as post-evaluation tooling, but as an active participant during compilation?

The full compiler framing is in `29_compiler-design.md`. This document focuses on the architectural role of Rust within Nix evaluation, and what that enables.

---

## 2. The Compiler Framing (Summary)

kix is not trying to abstract away Kubernetes. K8s resources map 1:1 — every field on every resource stays accessible. The language isn't the problem. The problem is **wiring**: keeping dozens of resources in agreement about names, labels, ports, permissions, and network paths.

The assembly → C analogy: assembly's problem was the language (registers, opcodes). K8s's problem is not the language (YAML is fine) — it's the wiring (selectors, port fan-out, RBAC triples, cross-namespace references). A K8s compiler keeps the resource language intact and compiles the wiring.

The goal: capture the **intent** of different personas (app dev, platform engineer, cluster operator) and compile it together into a safe cluster deployment.

---

## 3. The Nix Store as Compiler IR

The Nix store gives the compiler a Merkle DAG — content-addressed, dependency-aware, cryptographically verifiable — as its intermediate representation. Most "compiler features" are consequences of this structure that need to be exposed, not built.

### Properties we get structurally

**Automatic dependency tracking.** Nix's string context embeds store-path references when values are interpolated. The dependency graph falls out of the computation — you can't have an untracked dependency if you used the value.

**Exact change propagation.** Change a resource → its hash changes → dependents' hashes change → the cascade stops precisely where influence stops. Cryptographically proven blast radius.

**Determinism.** Same inputs → same hashes → same cluster. Byte-identical output across machines and CI.

**Closure computation.** Given any root, the store gives you the full transitive dependency set. The activation root gives you every resource in the cluster.

**Deduplication.** Identical content = identical hash = same store path. Detects both unintentional duplication and intentional sharing.

### What this enables

- **Minimal-diff deployment.** Compare activation DAGs by hash. Only apply what changed. This compares two known-good compiler outputs, not intent vs drifted reality.
- **Deployment wave ordering.** The DAG is a topological sort. Dependencies tracked via string context → wave ordering is correct without manual annotation.
- **Blast radius analysis.** Follow the DAG forward from a changed node. Every node with a new hash is in the blast radius. Exact, not heuristic.
- **Rollback as pointer swap.** Previous cluster state is still in the store — immutable, complete. Diff current vs rollback target trivially.
- **Cryptographic audit trail.** Every deployment and every resource is a hash. Provenance is a backward DAG walk.
- **Cross-cluster comparison.** Same packages + same config = identical hashes. Divergence pinpointed by walking the DAG.
- **Caching / incremental rebuild.** Unchanged inputs → same hash → cache hit. One package change in a 200-package cluster recomputes only the affected subgraph.
- **Parallel deploy safety.** Independent DAG subgraphs can deploy in parallel — the graph proves they can't interfere.
- **Garbage collection.** Resources not reachable from the activation root are garbage. Graph traversal, not file discovery.
- **"What if" analysis.** Build two variants, compare DAGs. Nix's purity guarantees the hypothetical build matches what a real build would produce.
- **Supply chain verification.** Tampering changes hashes, which breaks parent references. Detectable from the root down.

---

## 4. Why Nix + Rust (Not One or the Other)

### Why not replace Nix entirely

Every alternative language was evaluated (Dhall, CUE, Jsonnet, Nickel, Haskell, custom DSL). The blocker is the same in every case: **no string context equivalent.** String context — where interpolating a store path into a string automatically tracks the dependency — is what makes the Merkle DAG automatic and complete. Every other language would require explicit dependency declarations, which defeats the purpose.

Nix also provides: lazy evaluation (fixpoints for self-referential packages), the module system (typed config merging with priorities), function-argument introspection (DI resolution), and IFD (Helm bridge).

### Why not stay in pure Nix

Nix has fundamental limitations that matter for compiler passes:

- **No data structures beyond attrsets and lists.** No graphs, no sets, no indexes. Cross-resource analysis is O(n²) and painful to express.
- **No mutation / accumulation.** "Collect all selectors, check for duplicates" rebuilds the entire accumulator on every fold step.
- **No good error messages.** Nix gives stack traces. A compiler needs: "Service 'myapp/backend' selector `{app: backend}` matches 0 pods. Deployment 'myapp/backend' has labels `{app: backend-v2}`."
- **No efficient set operations.** Selector matching (is this label set a subset of that label set?) is the core K8s wiring question. Clunky and slow in Nix.
- **No state across evaluation boundaries.** Each expression is pure. Can't build an index incrementally as packages resolve.

### The hybrid

Nix handles what it's uniquely good at: functional evaluation, string context, lazy fixpoints, module system, content-addressed store. Rust handles what Nix can't: graph analysis, indexed queries, K8s schema knowledge, rich diagnostics.

---

## 5. Two Seats for Rust

### Seat 1: Inside the fixpoint (oracle)

The fixpoint (in `instance.nix` per-package, in `cluster.nix` cluster-wide) is where the compiler has **maximum information**. Every resource exists as a store path. Every dependency is resolved. Every `self.*` reference is settled. Full Nix string context is available. Config layers have merged.

After this point, information is only lost (serialized to JSON, stripped of context, emitted as YAML).

Rust sitting here — callable from Nix as an oracle — can answer questions that Nix can't practically answer. Nix asks, Rust answers. Nix decides what to do with the answers. Resource creation and wiring stays in Nix.

### Seat 2: Post-evaluation (existing CLI)

The current Rust CLI (`kix-eval`, `kix-manifest`, `kix-cluster`). Operates on the emitted store graph + JSON manifests. Handles operational concerns: diffing, wave computation, deployment, drift detection.

This seat is the right place for operational tooling but the wrong place for compilation checks — too much information has been lost by the time Rust sees it.

### The data flow with both seats

```
Nix evaluation begins
  ↓
  Module system merges persona configs
  ↓
  DI resolution + auto-instantiation
  ↓
  Per-package fixpoint begins
    ↓
    Package creates resources (Nix, store paths)
    ↓
    Package queries Rust oracle:           ← SEAT 1
      "Does my selector conflict?"
      "Is this CR valid against the CRD schema?"
      "Does this Secret reference exist?"
    ↓
    Rust indexes resources, answers queries
    ↓
    Package uses answers for diagnostics / conditional derivation
    ↓
  Per-package fixpoint settles
  ↓
  Cluster fixpoint settles
  ↓
  Emission: store paths → JSON manifests
  ↓
Rust CLI reads emitted graph               ← SEAT 2
  ↓
  stamp, diff, waves, apply, deploy
```

---

## 6. What Rust Does at the Fixpoint

### 6.1 Graph queries (indexed cross-resource analysis)

At the fixpoint, every resource exists. Rust builds a graph from resources (once, indexed), then answers queries Nix can't efficiently answer:

- "What resources in the cluster match this selector?" — requires indexing all resource labels
- "Does any NetworkPolicy already allow traffic from these pods to those pods on this port?" — requires traversing all NetworkPolicies and their selectors
- "What ServiceAccounts have access to this API group/resource?" — requires traversing all Role/ClusterRole + Binding chains
- "What other Services in this namespace select overlapping pods?" — requires selector cross-checking

Individual Nix packages can't answer these because they only see their own scope + injected deps. The cluster fixpoint could answer them in Nix, but as O(n²) linear scans with bad error messages. Rust builds an index and answers instantly.

### 6.2 Constraint solving (stateful accumulation)

Some wiring problems are constraint satisfaction that requires state across package evaluations:

- "Is port 8080 available on the shared LoadBalancer, or has another package already claimed it?" — Rust maintains allocated ports
- "Does this CIDR range overlap with any existing NetworkPolicy?" — interval analysis
- "Has another package in this namespace already created a resource with this name?" — name uniqueness per (kind, namespace)

Nix can't accumulate state across separate package evaluations without threading it through the entire computation. Rust maintains state naturally.

### 6.3 K8s schema-aware validation

K8s resources have dozens of name-reference fields: a volume mount references a volume by name, a volume references a ConfigMap by name, envFrom references a Secret by name, serviceAccountName references a ServiceAccount. These all follow the same pattern: a string field that must match an existing resource.

Encoding each one as a Nix assertion is tedious and error-prone — there are too many, they change across K8s versions, and CRDs add new ones. Rust can know the K8s OpenAPI schema for the target version and check all name-reference fields systematically:

- `volumes[].configMap.name` → must exist as ConfigMap in namespace
- `volumes[].secret.secretName` → must exist as Secret in namespace
- `serviceAccountName` → must exist as ServiceAccount in namespace
- `envFrom[].configMapRef.name` → must exist as ConfigMap in namespace
- Every CRD field with `x-kubernetes-resource-ref` or equivalent

One implementation covers all of them, across all K8s versions and CRDs.

### 6.4 CRD schema validation

When `mkCR` creates a custom resource, Rust validates against the CRD's OpenAPI schema with domain-aware errors:

"Field `spec.backup.retention` on SGCluster 'prod-pg' is `"30d"` (string), but CRD SGCluster requires an integer. Defined at packages/stackgres-cluster/default.nix:374."

Nix can check types. Rust can check types, know the OpenAPI type system natively, and produce errors that reference both the field and the schema.

### 6.5 Incremental whole-cluster analysis during compilation

Because Rust is called by multiple package fixpoints within the cluster fixpoint, it accumulates knowledge as packages resolve:

- Package A resolves → Rust indexes its resources
- Package B resolves, queries "does my selector conflict?" → Rust checks against A's index
- Package C resolves, queries "is this port available?" → Rust checks against A and B

This is whole-cluster analysis happening *during* compilation, not as a separate post-evaluation pass. Each package gets feedback about the cluster state as it's being built.

### 6.6 Rich diagnostics

Nix errors are stack traces. Rust at the fixpoint can produce compiler-quality diagnostics:

```
error[E0312]: selector mismatch
  --> packages/myapp/default.nix:47
   |
47 |     selector.matchLabels = { app = "backend"; };
   |                             ^^^^^^^^^^^^^^^^^^
   |
   = note: Service 'myapp/backend-svc' selects pods with {app: "backend"}
   = note: Deployment 'myapp/backend' templates pods with {app: "backend-v2"}
   = help: update the Service selector or the Deployment template labels
```

This requires knowing what a selector is, what a Service is, what a Deployment template is — K8s domain knowledge that lives naturally in Rust.

---

## 7. What Rust Does NOT Do at the Fixpoint

- **Resource creation.** Resources participate in the Merkle DAG, need store paths, need string context. Nix creates resources. Derived resources (NetworkPolicies, RBAC from connection graph, etc.) are created by Nix — potentially informed by Rust oracle answers, but the actual `mkResource` call is Nix.
- **Dependency resolution.** String context and the module system are the right tool. Rust can't inject Nix values into scope.
- **Config merging.** The module system with `mkDefault`/`mkForce` is purpose-built for this.
- **Modifying the evaluation.** Rust is an oracle. Nix asks questions, Rust answers. Rust doesn't modify the resource graph. Nix decides what to do with the answers.

The purity contract: calling Rust with the same inputs gives the same answers. The fixpoint converges the same way. Rust makes certain questions *answerable* that Nix can't practically answer.

---

## 8. The Oracle Interface

Conceptually, the Nix → Rust interface is a set of query functions:

```
# Nix calls these, Rust answers
oracle.indexResource resource    → null (side effect: adds to index)
oracle.checkSelector selector   → { conflicts = [...]; }
oracle.validateCR crd cr        → { errors = [...]; warnings = [...]; }
oracle.checkNameRef kind name ns → { exists = bool; suggestions = [...]; }
oracle.queryPortAvailability ns port → { available = bool; claimedBy = ...; }
```

The oracle is initialized once per cluster build. Nix calls `indexResource` as resources are created (inside fixpoints). Nix calls query functions to check invariants. Rust maintains internal state (indexes, graphs) across calls.

From Nix's perspective, the oracle is a pure function of the resources indexed so far — same resources indexed → same query results. The statefulness is an implementation detail that Nix doesn't observe (because fixpoint evaluation order is deterministic).

---

## 9. Open Questions

1. **FFI mechanism.** Current FFI (`kix-eval/ffi.rs`) evaluates complete expressions and gets JSON back. The oracle requires Nix-to-Rust calls during evaluation. This could be a Nix builtin registered via FFI, a foreign function exposed to the Nix evaluator, or a different mechanism entirely.

2. **Fixpoint ordering.** If Rust accumulates state across package fixpoints, the order packages are evaluated matters. Nix's lazy evaluation means evaluation order is demand-driven. Does this create problems for incremental indexing? Or does the fixpoint's convergence guarantee that by the time a query is answered, all relevant resources have been indexed?

3. **Granularity of oracle calls.** One call per resource? One call per package? One final validation call after the cluster fixpoint settles? The trade-off is between early feedback (catch errors during package evaluation) and complete information (all resources available for cross-checking).

4. **What data crosses the boundary.** The oracle receives resources (JSON) and string context metadata (store paths, dependency edges). What else? CRD schemas are needed for CR validation. K8s target version for API version checking. What's the minimal set that enables the checks described above?

5. **Interaction with intermediate fixpoints.** If derived resources (e.g., NetworkPolicies from connection graph) are created at intermediate fixpoints informed by oracle answers, and those derived resources are themselves indexed by the oracle, does this create circular dependencies? Or does the layering (package fixpoint → cluster fixpoint) naturally prevent this?
