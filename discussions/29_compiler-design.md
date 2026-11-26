# kix as a Kubernetes Compiler

## Working Document — March 2026

**Status:** Design exploration
**Related:** `08_v2_unified_rfc.md` (v2 design), `10_merkle_dag_package_instance.md` (content-addressed DAG), `16_module_system_personas_and_use_cases.md` (persona model), `24_package_instance_wiring.md` (DI/wiring)

---

## 1. The Core Insight

There have been many attempts to "abstract away" Kubernetes — mapping it to other programming languages, inventing higher-level constructs, building PaaS layers on top. These work for specific use cases but collapse on edge cases. If you deeply investigate every field on every K8s resource, there is always some scenario — however narrow — that makes that field's existence relevant. Kubernetes is an incredibly general technology applicable to almost every problem. **We do not try to make it more specific.**

This is why kix maps its resources 1:1 to actual K8s resources. The language is not the problem. Nobody struggles to write YAML. What is hard about Kubernetes is **wiring** — keeping dozens of resources in agreement about names, labels, ports, permissions, and network paths.

The analogy to the assembly → C transition is precise:

- **Assembly's problem** was the language itself — registers, opcodes, manual stack management. C replaced the language.
- **Kubernetes' problem** is not the language — it's the wiring. Resources reference each other by name strings, labels must match across boundaries, ports are declared redundantly, permissions are spread across 3 resources. A K8s compiler keeps the resource language intact and compiles the **wiring**.

The goal: capture the **intent** of different personas (app dev, platform engineer, cluster operator) and compile it together into a well-managed, safe cluster deployment.

---

## 2. What "Wiring" Means Concretely

Every K8s wiring problem follows the same shape: information declared in one place must be consistently repeated or referenced in other places. When it drifts, things break at runtime.

| Wiring problem | What you mean | What you write today |
|---|---|---|
| Service → Deployment | "route traffic to these pods" | Copy labels into selector, hope they match |
| Env var → Service | "I talk to postgres" | Manually construct `host:port` from another service's name |
| Port fan-out | "my app listens on 8080" | Declare the port in container spec, Service targetPort, Ingress backend, NetworkPolicy |
| RBAC | "I need to read secrets" | ServiceAccount + Role + RoleBinding (3 resources for 1 permission) |
| Storage | "I need 10Gi at /data" | PVC + volume entry + volumeMount, matched by name string |
| Network access | "A talks to B on port 5432" | NetworkPolicy allowing egress from A + ingress to B on that port |
| Cross-namespace ref | "I depend on the cluster's ingress controller" | Manually construct FQDN, hope the target exists |
| TLS | "this endpoint needs HTTPS" | Ingress TLS block + Certificate CR + Issuer reference by name |

A compiler eliminates these by making the wiring **derived from a single source of truth** rather than manually synchronized.

---

## 3. What kix Already Compiles

kix v2 is not starting from zero. Several wiring problems are already solved:

### 3.1 Dependency Injection (resolve.nix, auto.nix)

Packages declare dependencies as function arguments. The evaluator resolves them via DNS-like lookup (same-namespace first, then cluster-wide). Auto-instantiation fills in missing transitive deps. This eliminates the "how do I find the postgres instance" wiring — you get it injected.

### 3.2 Selector Auto-Derivation (k8s.nix, scope.nix)

`mkResource` auto-derives selectors from `spec.selector.matchLabels` or `metadata.labels`. `service.fromWorkload` reads the workload's selector and wires it into the Service. Selector mismatch within a package is already difficult (though not impossible — you can still override).

### 3.3 Content-Addressed Dependency Graph (k8s.nix)

Resources are Nix store paths. Interpolating `self.deployment.out.name` into a Service embeds the Deployment's hash into the Service's content. The compiler sees the full dependency graph, detects orphaned resources, redundant requires, and can compute deployment waves.

### 3.4 RBAC DSL (rbac.nix)

The intent-based RBAC API (`rbac.watch`, `rbac.reconcile`, `rbac.own`) already compiles high-level permission intents into K8s Role rules. `grant` merges and deduplicates. `mkRoleSet` / `mkClusterRoleSet` emit the SA + Role + Binding triple from a single declaration.

### 3.5 Diagnostic System (meta.nix, instance.nix)

K8s version bounds, dependency compatibility, conflict detection, orphan warnings — these are compile-time errors, caught before any YAML reaches a cluster.

---

## 4. What kix Does Not Yet Compile

The gaps fall into categories: **wiring that is still manual**, **invariants that aren't checked**, and **cross-cutting concerns that require whole-cluster analysis**.

### 4.1 Connection Wiring

The biggest gap. When package A depends on package B via DI, A gets B's `out` — but the actual wiring (env vars, config entries, DNS references) is still manual string construction inside the package.

```nix
# Current: manual wiring inside the package
env = kix.mkEnv {
  DATABASE_HOST = postgres.out.fqdn;      # manual
  DATABASE_PORT = toString postgres.out.port;  # manual
  REDIS_URL = "redis://${valkey.out.fqdn}:${toString valkey.out.port}";  # manual
};
```

The compiler knows A depends on B. It knows B exposes a port. But the actual connection — the env var — is an opaque string. If B changes its port, the compiler can't tell A about it (beyond Nix's lazy eval failing if `out.port` disappears entirely).

**Compiler opportunity:** Connections as first-class edges in the dependency graph. A declares "I connect to postgres" and the compiler derives: env vars, NetworkPolicy rules, and can verify the port exists on the target. The package still controls *how* the connection is consumed (env var name, URL format), but the compiler validates the wiring is consistent.

### 4.2 Network Policy Derivation

If the compiler knows the connection graph (which packages talk to which), NetworkPolicies are derivable rather than hand-written. The platform engineer declares the default posture (deny-all, allow-same-namespace, etc.) and the compiler emits policies that permit exactly the declared connections.

This is analogous to how RBAC intents already work — you don't hand-write rules, you declare intents and the compiler lowers them.

### 4.3 Port Fan-Out

A container port is currently declared in the workload spec, then re-declared in the Service, then referenced in the Ingress backend, then referenced in NetworkPolicy. `service.fromWorkload` handles the Service derivation but stops there.

**Compiler opportunity:** A port declared once on the workload propagates automatically to every resource that needs it. The Service, Ingress backend port, and NetworkPolicy port all derive from the single declaration. Changing the port means changing one number.

### 4.4 Exposure / Ingress Compilation

"This service is publicly reachable at app.example.com" currently requires: Service + Ingress resource + TLS block + Certificate CR + Issuer reference. These are all wiring the same intent: "expose this, with TLS, at this domain."

**Compiler opportunity:** An exposure declaration on the package that the evaluator lowers to the right resource set. Crucially, this doesn't hide the resources — they're still standard K8s resources in the output. It eliminates the manual wiring between them.

### 4.5 Storage Wiring

PVC + volume + volumeMount is three declarations that must agree on a name string. The `mount.pvc` helper partially addresses this but it's still explicit plumbing.

**Compiler opportunity:** Storage as a property of the workload. `{ size = "10Gi"; mountPath = "/data"; }` compiles to all three resources with consistent naming. The escape hatch (raw volume/volumeMount) remains for edge cases.

### 4.6 Cross-Resource Reference Validation

When a resource references another resource by name (CRD field pointing to a ConfigMap, Ingress annotation referencing a ClusterIssuer, etc.), the compiler currently doesn't validate that the target exists. These are string fields in the manifest — invisible to the dependency graph.

**Compiler opportunity:** Typed references. When `.out.name` is used in a CRD field that the compiler knows is a resource reference, it can verify the target exists in the cluster build. This requires knowing the semantics of specific fields — a form of CRD schema awareness.

### 4.7 CRD Schema Validation

`mkCRD` already carries an OpenAPI v3 schema. But CRs created via `mkCR` are not validated against it. If a field is misspelled, has the wrong type, or violates an enum constraint, the error surfaces only when the operator processes the CR at runtime.

**Compiler opportunity:** Validate CRs against their CRD's schema at Nix eval time. Typos in field names, invalid enum values, missing required fields — all caught at build time.

### 4.8 API Version / Deprecation Checking

`k8sVersion` is a cluster config option but isn't used to check `apiVersion` fields on generated resources. Using a removed API version (e.g., `extensions/v1beta1` on K8s 1.22+) is a runtime error.

**Compiler opportunity:** A pass that checks every resource's `apiVersion` against the target cluster version's deprecation/removal schedule.

---

## 5. Compiler Passes: A Taxonomy

Organizing the above into a model of what a "K8s compiler" actually does:

### Pass 1: Resolution (already exists)

Resolve package dependencies, auto-instantiate missing deps, build the instance graph. This is the DI / module system / auto-instantiation layer.

**Input:** Cluster modules (persona declarations)
**Output:** Fully resolved instance graph with configs

### Pass 2: Compilation (partially exists)

Each package builds its resources. `scope` provides the constructors. Labels, selectors, and some cross-resource wiring are auto-derived.

**Input:** Resolved instance + config + deps
**Output:** Resource DAG per package

**Gaps to close:**
- Connection wiring (env vars, ports) still manual
- Exposure compilation (Service + Ingress + TLS from single declaration)
- Storage compilation (PVC + volume + mount from single declaration)

### Pass 3: Wiring Validation (partially exists)

Check that cross-resource references are consistent. Selectors match. Ports agree. Required fields present.

**Input:** Resource DAGs from all packages
**Output:** Diagnostics (errors, warnings)

**Currently:** `checks.nix` and `pi-checks.nix` handle some of this. Orphan detection and redundant-requires in `instance.nix`.

**Gaps to close:**
- Cross-namespace reference validation
- CRD schema validation for CRs
- Port consistency across Service → Ingress → NetworkPolicy chains
- Name-reference validation (does the referenced ConfigMap/Secret/Issuer exist?)

### Pass 4: Derivation (mostly missing)

Generate resources that are implied by the intent graph but not explicitly declared. This is where the compiler adds value beyond what a framework can do — it sees the whole cluster and derives cross-cutting resources.

**Input:** Full cluster resource graph + connection graph + policies
**Output:** Additional resources (NetworkPolicies, RBAC bindings, PDBs, etc.)

**Examples:**
- NetworkPolicies derived from connection graph + platform posture
- RBAC derived from declared API access needs (already partially exists)
- PodDisruptionBudgets derived from workload lifecycle type
- Default resource limits derived from namespace quotas

### Pass 5: Whole-Cluster Analysis (mostly missing)

Checks that require seeing the entire cluster at once, not just individual packages.

**Input:** Complete cluster manifest set
**Output:** Diagnostics

**Examples:**
- Selector uniqueness (no two Services selecting the same pods unintentionally)
- Port conflicts on shared LoadBalancers
- Resource quota fit (do declared resources fit within namespace quotas?)
- Network reachability (can traffic actually flow from Ingress to Service given NetworkPolicies?)
- API version compatibility with target K8s version

### Pass 6: Emission (exists)

Lower the validated, derived resource set to content-addressed YAML files. Build the PackageInstance DAG, activation CRD, and package index.

---

## 6. Persona-Driven Intent Model

The compiler's power comes from capturing intent at different abstraction levels and compiling them together. Each persona operates at a different level:

### App Developer

Declares: "I have a web service that talks to postgres and listens on port 8080. It needs 10Gi of storage at /data."

Does NOT care about: selectors, RBAC rules, NetworkPolicy details, PDB configuration, Ingress annotations, certificate management.

The compiler derives all of that from the declaration + platform defaults.

### Platform Engineer

Declares: "All workloads get deny-all network policy by default. Connections between declared dependencies are permitted. All public endpoints use cert-manager with this ClusterIssuer. Resource quotas per namespace."

Does NOT write per-service policies. Instead, declares the rules, and the compiler applies them to every service.

### Cluster Operator

Declares: "This cluster runs K8s 1.29 in eu-west-1 with these storage classes and this ingress controller."

The compiler uses this to validate API versions, set cluster-specific defaults, and verify that declared storage classes exist.

### The Compilation

These three layers merge (via the module system, which already supports this) and the compiler resolves conflicts, applies priorities, and emits a consistent cluster. The key: each persona writes only what they care about, and the compiler handles the cross-cutting wiring between layers.

---

## 7. Design Principles for Compiler Features

### 7.1 Resources Stay Real

Every compiled output is a standard K8s resource. No custom runtime, no CRDs required for kix itself (PackageInstance is for deployment orchestration, not for the compiler). A cluster built by kix is indistinguishable from one built by hand — just more consistent.

### 7.2 Wiring Is Compiled, Not Hidden

The compiler derives Services, NetworkPolicies, RBAC from declarations. But the output is visible, diffable, and overridable. You can always inspect what got generated and why. The compiler is transparent.

### 7.3 Escape Hatches Are First-Class

`scope.mkResource` remains available for anything the compiler doesn't model. Raw K8s fields are always accessible. The compiler handles the 90% case; the escape hatch handles the 10%. Critically, the compiler should be able to **track** what's escaped — "these 3 fields are uncompiled raw values" — so you know where the safety guarantees end.

### 7.4 Errors Should Be Impossible, Not Detected

The priority order:
1. **Make the error structurally impossible** (best) — e.g., selectors derived from a single source
2. **Detect the error at eval time** (good) — e.g., CRD schema validation
3. **Warn about unchecked territory** (acceptable) — e.g., "this raw string field references a resource name the compiler can't verify"

Validation is a fallback for when compilation can't eliminate the error class entirely.

### 7.5 The Compiler Sees the Whole Cluster

Single-package checks are necessary but insufficient. The valuable checks are cross-package, cross-namespace, and cross-persona. The module system already merges everything into one evaluation — the compiler should exploit that for whole-cluster analysis.

---

## 8. The Nix Store as Compiler IR

It is no accident that kix is built on Nix. The Nix store gives the compiler a Merkle DAG — content-addressed, dependency-aware, cryptographically verifiable — as its intermediate representation. Most of the "compiler features" described in this document are not things we need to build from scratch. They are **consequences of the Merkle DAG** that we need to expose.

### 8.1 Structural Properties We Get for Free

**Automatic dependency tracking.** When package A interpolates `postgres.out.fqdn` into an env var, Nix's string context mechanism embeds postgres's store hash into A's content. The dependency edge isn't declared — it falls out of the computation. The dependency graph is always complete and always correct. You can't have an untracked dependency if you used the value.

**Exact change propagation.** Change a ConfigMap's content → its hash changes → every resource that interpolated from it gets a new hash → their dependents get new hashes. The cascade stops precisely where the influence stops. Not "might be affected" — **cryptographically proven** affected. This is blast radius computation for free.

**Determinism as a structural guarantee.** Same inputs → same hashes → same cluster. Not "should produce the same output" but "mathematically must." Two people building the same commit get byte-identical output. A CI build and a local build are provably the same.

**Closure computation.** Given any resource (or package root), the store gives you the full transitive dependency set. Given the activation root, you have every resource in the cluster. This is a complete manifest inventory derived from graph traversal, not file discovery.

**Deduplication / sharing.** If two packages produce an identical resource (same content → same hash), it's literally the same store path. You can detect unintentional duplication (two packages creating the same RBAC rule) and intentional sharing (same ConfigMap referenced by multiple consumers).

### 8.2 What This Enables for the Compiler

**Minimal-diff deployment.** Compare two cluster builds by comparing their activation DAGs. Walk both trees. Nodes with the same hash are unchanged — skip them. Nodes with different hashes or new/removed nodes are the diff. The deploy applies only what changed. This is qualitatively different from `kubectl diff`, which compares YAML against live state (which may have drifted). Merkle comparison compares two known-good states — the diff is between two compiler outputs, not between intent and reality.

**Deployment wave ordering.** The DAG is a topological sort waiting to happen. Resources with no dependencies deploy first. Resources that depend on them deploy next. The compiler doesn't need a separate "wave" annotation — the dependency structure IS the wave structure. And because dependencies are tracked automatically via string context, the wave ordering is always correct without manual declaration.

**Blast radius analysis (pre-deploy).** Before deploying: "If I change this value, what gets redeployed?" Follow the DAG forward from the changed node. Every node with a new hash is in the blast radius. This isn't a heuristic — it's exact. A platform engineer can see that changing a shared ConfigMap affects 12 Deployments across 4 namespaces, and decide whether to proceed.

**Rollback as pointer swap.** Every cluster state is a store path (the activation root). Rolling back means pointing to the previous activation root. The entire previous state is still in the store — immutable, content-addressed, complete. You don't "reconstruct" the previous state, you literally have it. And you can diff current vs rollback target to see exactly what would change.

**Cryptographic audit trail.** Every deployment is a hash. Every resource in that deployment is a hash. You can answer: "What was deployed at time T?" → the activation hash. "What was the exact content of resource X at time T?" → its store path. "Has anything changed since the last audit?" → compare hashes. This is Git-level auditability for live infrastructure, and it comes free from the store model.

**Provenance / "why does this exist?"** For any resource in the cluster, walk the DAG backward: what depends on it? Walk further: why does that exist? You can trace any resource back to the package that created it and the cluster config that instantiated that package. "Why is this NetworkPolicy here?" → because package A declared a connection to package B, and the compiler derived the policy. The full causal chain is in the graph.

**Cross-cluster comparison.** Two clusters built from the same packages with the same config produce identical hashes. Clusters that should be identical (staging vs prod mirror) can be verified by comparing activation hashes. If they differ, walk the DAG to find exactly where they diverge. "Staging and prod differ in exactly 3 resources, all in the ingress-nginx package, because prod has `replicas: 3` and staging has `replicas: 1`."

**Caching / incremental rebuild.** Nix already caches store paths. If a package's inputs haven't changed, its output hash is the same, and nothing is recomputed. Change one package in a 200-package cluster → only that package and its dependents are re-evaluated. The rest are cache hits. This makes the compiler fast even for large clusters.

**Parallel deploy safety.** Independent subgraphs in the DAG (no shared edges) can be deployed in parallel with zero coordination. The DAG proves they can't interfere with each other. Dependent subgraphs are sequenced automatically. This isn't a heuristic — it's a mathematical property of the graph structure.

### 8.3 Capabilities Unique to a Merkle-Backed Compiler

These go beyond what a conventional K8s tool could achieve — they are only possible because the compiler's IR is a content-addressed DAG.

**Semantic change detection.** Forget textual diffs. Two resources have the same hash → they are identical. Different hash → something meaningful changed. A CI check can say: "This PR changes 0 resource hashes in the cluster build" → safe to merge without deployment. Or: "This PR changes 47 resource hashes" → needs careful review. The hash IS the semantic fingerprint.

**Package-level impact contracts.** A package can declare: "My `out` interface is stable if my hash doesn't change." Consumers that depend on `out.fqdn`, `out.port`, `out.selector` can verify: did the upstream package's hash change? If not, the contract is guaranteed preserved. If yes, check if `out` fields changed — if the hash changed but `out` didn't (internal refactor), consumers are unaffected and the DAG proves it (their hashes won't change either since the interpolated values are the same).

**Drift detection with cryptographic precision.** The deployed state was activation hash X. Dump the live cluster. Content-hash every live resource. Compare against the store. Any mismatch is drift — and you know exactly which resources drifted and what the expected content is. This is `kix-diff` but with the mathematical backing of the Merkle structure rather than textual YAML comparison.

**"What if" analysis.** Want to know what happens if you upgrade postgres from 15 to 16? Build both. Compare DAGs. The diff tells you exactly which resources change, in which packages, in which namespaces. Before touching anything. Nix's purity guarantees this "what if" build is identical to what the real build would produce.

**Garbage collection / pruning.** Resources not reachable from the activation root are garbage — they shouldn't exist in the cluster. The store model makes this a graph traversal. Pruning isn't "delete things that aren't in my YAML directory" (fragile, breaks on file moves) — it's "delete things not reachable from the root" (correct by construction).

**Supply chain verification.** Every resource's content is hashed. Every dependency is a hash reference. You can verify that a built cluster hasn't been tampered with by checking hashes from the activation root down. If someone modifies a resource's content, its hash changes, which breaks the reference from its parent. The Merkle structure makes tampering detectable without trusting any individual component.

**Lazy evaluation + the DAG = surgical debugging.** Nix is lazy. You can evaluate just one package, just one resource, just one `out` field — without building the entire cluster. But when you do build the full cluster, the DAG connects everything. This means: fast local iteration on one package, with full-cluster validation in CI. The same codebase supports both workflows because laziness lets you choose your evaluation scope.

### 8.4 The Meta-Insight

The Nix store already has all this information. The DAG already encodes blast radius — surface it as a query. The hashes already detect drift — surface it as a diff tool. The closure already defines deploy scope — surface it as wave ordering. The graph already proves parallel safety — surface it as a deploy strategy.

Most of the compiler's power is not in building new analysis engines. It is in **exposing what the Merkle DAG already knows** through the right interfaces: CLI queries, CI checks, deploy tooling, and error messages that point back through the graph to the root cause.

The Nix store is the compiler's intermediate representation. We chose it on purpose.

---

## 9. Why Nix + Rust (Language Evaluation)

### 9.1 The non-negotiable requirement

The feature that makes kix's architecture work is **automatic dependency tracking through string context**. When you interpolate `postgres.out.fqdn` into a resource, Nix embeds postgres's store hash into the consuming resource. The dependency edge isn't declared — it falls out of the computation. This gives us the Merkle DAG, which gives us everything in section 8.

Any replacement language must provide an equivalent, or the entire architecture collapses back to explicit dependency declarations.

### 9.2 Alternatives evaluated

**Dhall.** Real type system (the biggest thing Nix lacks). Total, imports with integrity checking. But: strict evaluation (no fixpoints for self-referential packages), no string context equivalent, no module system, and totality prevents general recursion needed for auto-instantiation's transitive closure. Dhall is designed for *validating* configuration, not *computing* it. kix needs computation.

**CUE.** Types-as-values, unification-based merging (similar in spirit to the module system), built-in constraints, created by an ex-Borg engineer. Unification could replace parts of the module system. But: no string context, strict evaluation, no function-argument introspection (DI resolution depends on this), deliberately Turing-incomplete. CUE would be excellent for validation passes but can't serve as the full compiler foundation.

**Jsonnet.** Functional, lazy (like Nix), hermetic, JSON-native, widely used for K8s (Tanka, kube-prometheus). Lazy evaluation means fixpoints work. But: no string context, no store, no module system (object merging is much weaker), no function-argument introspection, no IFD. Jsonnet is Nix without the features that make kix possible.

**Nickel.** Nix-inspired, lazy evaluation, contracts (gradual typing), merge system inspired by NixOS modules. The closest alternative — fixpoints work, composition works, better error messages than Nix. But: explicitly chose not to replicate string context. If Nickel added a context-tracking mechanism, it could work — with years of infrastructure investment to match the maturity of what Nix provides today.

**Haskell.** Most powerful type system of any production language, lazy by default, could model string context as a writer monad. GADTs could make invalid resource references unrepresentable. But: you'd build everything from scratch (store, module system, content addressing, Helm bridge). And cluster definitions would be Haskell programs — the app-developer persona doesn't want to learn Haskell to deploy a web service.

**Rust / Go as the configuration language.** Rich ecosystems, familiar. But: strict evaluation, no purity guarantees, no content addressing. These make sense as compiler implementation languages, not as the language users write packages in.

**Custom DSL.** Design everything purpose-built: string context, lazy evaluation, type system, module system, K8s-aware primitives. Theoretically ideal, but 3-5 years of language engineering before you can build the compiler on top.

### 9.3 Summary

| Language | String context | Lazy eval | Module system | Types | Verdict |
|---|---|---|---|---|---|
| **Nix** | native | native | mature | none | Strong foundation, weak error UX |
| **Nickel** | no | yes | immature | contracts | Closest alternative, missing the key feature |
| **Haskell** | buildable (monad) | native | build from scratch | excellent | Right for compiler impl, wrong for config language |
| **Dhall** | no | no | no | strong | Too restrictive for computation |
| **CUE** | no | no | unification | built-in | Good for validation, not full compiler |
| **Jsonnet** | no | yes | weak | none | Nix without the magic |
| **Custom DSL** | designable | designable | designable | designable | Years before you start |

### 9.4 The decision: Nix as frontend, Rust as backend

Nix stays because string context is irreplaceable. Its weaknesses (no types, bad errors, no graph operations, no efficient set operations, no state accumulation) are precisely what Rust compensates for. The architecture described in `36_rust_oracle_at_fixpoint.md` — Rust as a query engine callable from Nix during fixpoint evaluation — addresses Nix's limitations without giving up its unique strengths.

The Rust CLI (`cli/`) already implements the post-evaluation backend: structural diffing with K8s semantics, wave computation, SSA-based deployment. The next evolution is Rust at the fixpoint — an oracle that provides graph queries, constraint solving, schema validation, and rich diagnostics during Nix evaluation, where all context is available.

This isn't a compromise. It's the strongest version of both: Nix for what only Nix can do (automatic dependency tracking, lazy fixpoints, functional resource construction), Rust for what Nix fundamentally can't do (indexed analysis, accumulated state, domain-aware error messages, K8s schema knowledge).

---

## 10. Concrete Next Steps (Rough Priority)

Ordered by: how much "compiler behavior" does the user experience, relative to effort.

### Tier 1: Close Gaps in Existing Passes

These extend what's already built:

- **CRD schema validation at eval time** — `mkCRD` already has the schema, `mkCR` just needs to check against it. Catches typos, wrong types, invalid enums.
- **API version / deprecation checking** — `k8sVersion` is already a config option, just needs a pass that checks `apiVersion` fields against the deprecation schedule.
- **Cross-namespace reference validation** — extend the forward-closure mechanism to verify that `ref.*.out.*` targets actually exist.

### Tier 2: Connection Graph

The highest-leverage new concept:

- Formalize the connection between packages as a typed edge (not just DI injection).
- Derive NetworkPolicies from the connection graph.
- Validate port consistency along connection paths.
- Enable env-var wiring that is checked against the target's `out` contract.

### Tier 3: Derived Resources

Resources the compiler generates from intent declarations:

- Exposure compilation (workload + exposure level → Service + Ingress + cert)
- Storage compilation (storage declaration → PVC + volume + mount)
- PDB / HPA derivation from workload lifecycle declarations

### Tier 4: Whole-Cluster Analysis

The most "compiler-like" behavior — errors no other tool catches:

- Selector uniqueness across the cluster
- Resource quota fit analysis
- Network reachability verification (given all NetworkPolicies, can traffic flow?)
- Unused resource detection cluster-wide

---

## 12. Open Questions

1. **Connection syntax:** How should a package declare "I connect to postgres on port 5432"? Should it be part of the function signature, a separate `connections` declaration, or derived from `out` field usage?

2. **NetworkPolicy ownership:** When the compiler derives a NetworkPolicy from the connection graph, which package "owns" it? The source? The target? A platform-level policy package?

3. **Escape hatch tracking:** How granular should the "uncompiled field" tracking be? Per-resource? Per-field? Is it a warning or just metadata?

4. **Incremental adoption:** How do packages migrate from manual wiring to compiler-managed wiring without a flag day? Can the compiler detect "you're manually doing what I could derive" and suggest migration?

5. **Persona boundaries:** How does the module system enforce that app devs can't override platform-engineer policies? (`mkForce` exists, but is it sufficient, or do we need a stronger permission model for module layers?)
