# The ideas behind authoring

Companion to the reference (01-03). The reference says *what the API is and how to use it*. This says *why it is shaped that way*: the principles that, once internalized, make the API feel predictable. Grounded in the repo's own design reasoning (`CLAUDE.md` DSL principles, `v2_discussions/100_package_dsl_ergonomics_survey.md`).

## 1. Kix is a compiler; authoring is writing source

- A package is not a deploy script. It is source for a compiler that produces a verifiable artifact, evaluated and checked before anything touches a cluster.
- Consequence for the author: describe *intent* (what exists, what depends on what), not *procedure* (apply this, then that). Ordering, policy, and wiring are the compiler's job to derive.
- Everything below follows from this. The API keeps moving decisions from deploy time to eval time, because eval time is where the author can be told they are wrong.
- See 01-fundamentals.md#overview--mental-model.

## 2. Every feature answers one of two questions

The design filter the repo applies to every proposed helper (`v2_discussions/100`):

- **Is the K8s shape itself wrong?** Then Kix models it differently - an *abstraction*. Example: optionality is a package feature (`scope.mkOptional`), not `null`-checks scattered through `requires`. Example: a permissioned identity is one concept K8s splits across ServiceAccount + Role + Binding, and `mkRoleSet` collapses the Role+Binding half.
- **Is the shape fine, but you should not have to type it?** Then Kix adds a *code-saver*: a helper that emits the standard shape (`kix.mount.*`, `out.url`, the label stack).

A proposal that is neither, that only reformats correct K8s for taste, does not ship. This is why the surface looks uneven on purpose: a few new concepts, mostly thin helpers over plain K8s.

## 3. Automation over brevity

- Helpers exist to make a *class of mistake* unrepresentable or caught at eval, not to save keystrokes. Each one traces to a real bug found in a real package.
- A selector that matches no pods, a cross-namespace mount, `limits < requests`, a secret-key typo, a forgotten deploy-ordering edge: all become eval-time errors instead of cluster surprises (see the validators in 02-authoring.md#workloads).
- The DSL is opinionated and rejects manifests that raw YAML would accept, because catching the mistake at eval is the goal.

## 4. The dependency graph is a side effect of using values

- There is no `dependsOn` field. The single act of referencing `self.x.out.name` gives the value and records the edge through Nix string context (see 03-advanced.md#store-path-context-and-closure-internals).
- One source of truth: you cannot read the value and forget the edge, because they are the same string.
- You declare a dependency by hand (`requires` / `extraDeps`) only when no value flows between two resources. See 02-authoring.md#resources-and-the-out-surface.

## 5. Ask for a role, not an instance

- A package declares "I need a `postgres`," never which one. The cluster resolves by name or alias (DNS-like DI, see 02-authoring.md#dependency-injection).
- This decouples a package from cluster topology. The same package runs against an in-cluster database, a managed one, or an import, with no package changes.
- The cost is resolution that looks implicit. The system pays it back by making ambiguity a hard error rather than a silent pick (see idea 8).

## 6. Stay K8s-shaped

- The DSL manipulates standard manifest fields. `mkResource` takes real `apiVersion`/`kind`/`spec`; helpers return K8s fragments (`kix.port`, `kix.mkEnvVars`); `extra` is forbidden from shadowing managed fields.
- A parallel vocabulary would be a second thing to learn, a place to diverge from K8s semantics, and a source of opacity. What the author writes maps to what the cluster sees.
- Abstractions (idea 2) are the deliberate exceptions, taken only where the K8s shape genuinely fights the author.

## 7. Resources are rich objects, not strings

- A resource is queried through `out`, not string-interpolated. `out.{name,fqdn,selector,url,identityHash}` are derived and carry context (see 02-authoring.md#resources-and-the-out-surface).
- Prefer `self.svc.out.name` over `"${self.svc}"`: the first is the contract surface and the edge carrier, the second is a stringly-typed coupling that drops information.
- Producers expose what consumers need on `out`; consumers never reach into a producer's internals.

## 8. Three things the DSL refuses to do

Self-imposed limits, generalized from the port-DSL exploration in `v2_discussions/100`:

- **No magic on resources.** A read-through convenience may exist, but the source of truth is always the author's explicit declaration, never an inferred property.
- **Ambiguity throws, never silently resolves.** Two candidate deps, or a multi-workload Service with no explicit port, surface the ambiguity instead of guessing.
- **Cross-cutting concerns are opt-in.** A workload with five ports does not auto-expose five; exposure and monitoring are chosen, not inferred.

These limits are what make derivation (idea 9) trustworthy: it fires only where the intent is unambiguous.

## 9. Declare intent, derive mechanism

- The author states relationships; the compiler emits the machinery. Network policy is derived from the dependency graph, selectors and labels from the workload, deploy waves from the store DAG (see 03-advanced.md#networking--package-meta).
- A package author writes almost no NetworkPolicy. They declare deps and, only for edges the graph cannot see (the open internet, opaque Helm internals), add a `meta.network.intents` entry.
- The cost is a black box when derivation is blind. The escape hatches (`intents`, `extraEdges`) exist for exactly those gaps and are meant to be rare.

## 10. Capabilities have owners; consumers borrow

- A resource that belongs to a capability (storage owns PVCs, reflection, monitoring) is obtained from that capability's owner via a DI builder, not hand-rolled (see 03-advanced.md#networking--package-meta, `meta.roles`).
- Single responsibility across package boundaries: one package owns "how storage is provisioned," everyone else asks for it.
- This is policed, not just suggested. A raw PVC is an eval error unless the package holds `meta.unsafe = [ "raw-pvc" ]`, and `architecture.annotationDomainOwnership` fires on an operator's annotations without a dependency on that operator.

## 11. Compose by adding behaviors

- Optional cross-cutting concerns are functions appended to a `build` list; each brings its own DI deps and resources (`kix.expose`, `kix.monitor`; see 02-authoring.md#composition-helpers-kix and 02-authoring.md#dependency-injection).
- This beats a single package with a hundred boolean options. Behavior is added by composition, not toggled by configuration.

## The through-line, and what it costs

- Every idea pushes the same direction: describe intent once, in K8s terms, let the compiler derive the rest, and get told at eval time when it cannot.
- The recurring cost is indirection (the final manifest is package plus instance plus flavor plus overlays, never one file) and an implicit graph (a hardcoded string silently drops an edge).
- The scorecard enforces the discipline these ideas assume rather than leaving it to convention (see 03-advanced.md#scorecard--rules): `selectorCoherence` and `fqdnWithoutContext` fail the build when a value carries no context, and the raw-PVC check fails it when a package hand-rolls a claim instead of taking `storage` by DI.
