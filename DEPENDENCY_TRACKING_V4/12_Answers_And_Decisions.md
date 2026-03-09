# 12: Answers and Decisions

Recording Luca's answers to the open questions from doc 11, plus additional
feedback. Adam's decisions on the items delegated to him follow.

---

## Luca's answers (2026-03-09)

### Question 1: Attrsets vs derivations

**Answer: Derivations — but skip for now.**

> "The final output should be derivations and the codebase should make it
> natural in the DSL to create dependency paths (ref pattern). So no 'explicit'
> names of resources are allowed. Finally the derivations created should reflect
> their dependencies through runtimeDependencies to their respective nix store
> paths. How exactly this gets done I am open to, but the DAG needs to be
> preserved."

He's clear on the end state (derivations with a DAG via runtimeDependencies)
but explicitly happy to defer: "we can — for now — skip this and purely work
on the DSL side of things. How a 'k8s cluster looks like when defined in nix.'
And only afterwards make sure we have a guarantee in place to make reality fit
the compilation (hashes). This will need a LOT of learning still. So happy if
we skip it for the sake of getting to a working version quickly."

**Implication:** We build on attrsets now. The DSL we design should not
*prevent* a later move to derivations, but we don't need to implement it yet.

### Question 2: The ref type system

**Answer: Answered via #1 — defer.**

> "Answered via 1 — up to you Adam if you want to do the first major migration
> without the DAG dependencies — we can also skip it for now."

### Question 3: Registry as capability

**Answer: Module system eventually, keep separate for now.**

> "Registry should be handled through the module system but for now can be kept
> separate."

### Question 4: Chart isolation mechanism

**Answer: No top-level "charts" concept, but metadata is welcome.**

> "No need for the concept of 'charts' on the toplevel, however a nixpkgs-like
> metadataset could be cool to also denote the current valkey version etc."

This means we keep the current flat `services.<name>` layout. The idea of a
metadata attrset (version, upstream URL, etc.) is a nice-to-have, not blocking.

### Question 5: Capability interface shape

**Answer: Start with Prometheus, design as you go, keep it contract-based.**

> "Focus on being prometheus compatible for now and design the API as you go
> along to make it work. However treat the module like a contract and not a
> tight coupling."

### Question 6: RBAC DSL scope

**Answer: Up to Adam.**

### Question 7: Combinator implementation details

**Answer: Implementation detail, not a requirement.**

> "This was never something I explicitly wanted — this is an implementation
> detail and should be treated as such. If it is important to make things work,
> keep it, otherwise ignore it, up to you."

### Question 8: Resource naming (store paths vs static)

**Answer: Replacement — but skip for now.**

> "Ideally, and also in the final version — I would use it as REPLACEMENT. My
> kix experiment creates these resources and a `kix` library would remove
> /nix/store from all paths, and insert the name field, and wrap kubectl get
> etc. This is the big part of how to manage the gitops part."

But pragmatically:

> "We can — for now — skip this and purely work on the DSL side of things."

So Luca's vision is full store-path naming with a `kix` CLI that maps hashes
back to human-readable names (like `nix build` vs `nix-store --query`). But
he's happy to defer this entirely. We keep `kixlib.resourceName` for now.

---

## Additional feedback from Luca

### On `//` (merge operator)

> "This is a naive merge btw: `a // b`. If you know what a and b are it is
> often safe, but let's say `a = { key = { a = 1; }; }` and
> `b = { key = { b = 2; }; }` — then `a // b` is actually just `b` because
> they conflict on the `key` key already, where b wins. So it is not a nested
> or 'deep' merge. Just to keep in mind."

Explains why he used `recursiveMerge` in the original kix. Relevant for
combinator design — combinators that modify nested attrsets need deep merge,
not `//`.

### On 10C (workload DSL example)

> "I don't like 10C but not because its nix is bad, but because its DSL design
> is shit. It doesn't use the module system and instead has a key 'enable' in
> its output."

The "today" code section was well received:

> "This is a great summary of a complaint I had as feedback on your first try
> I think :D"

The DSL direction is right but the example has a design flaw — the `enable`
key should be a module system option, not a field in the combinator output.

### On metrics port duplication

> "I like the DSL it is building but it does the typical 'confident mistake' of
> Claude — like it proudly points out you don't want to define things in
> multiple places, but then has the metrics port defined once on container level
> and once when using withMetrics."

Valid criticism. The metrics port should be declared once (on the container)
and `withMetrics` should *read* it from the resource bundle, not require it
again as a parameter.

### On the valkey mkStatefulService example

Luca **loves** this pattern:

> "I LOVE this. What do you think? Would love it to do a `let .. in` though to
> reuse 90% of the code. Or even have the option that withPersistence overrides?
> So you could take valkey-primary, copy valkey replicas and just override
> storageClass to fast."

> "But LOVE the direction since this makes it much more explicit what a kix DSL
> would need to support."

---

## Adam's decisions (2026-03-09)

### Question 2: Skip refs for first migration?

**Decision: Skip refs.** Use plain strings like today. The ref/DAG system is
entangled with the derivation work Luca wants to defer — designing validation
now risks building something that gets thrown away. Add refs later when
derivations arrive.

### Question 6: RBAC DSL — build as part of V4 or after?

**Decision: Defer.** Keep current `mkRoleSet` + raw verbs. The DSL is additive
polish, not architectural — it can be shipped separately anytime without
touching anything else.

### Question 7: Combinators — what scope?

**Decision: Pipes without `_extraConfig`, proof-of-concept scope.** Build
combinators that transform resource bundles (the pipe syntax Luca loves), but
charts still declare capabilities manually via module options. Keep it minimal
— a proof of concept to show the idea works, not an extensive framework. The
full `_extraConfig` auto-declaration pattern is deferred until the capability
system is proven and the DSL design issues (metrics port duplication, `enable`
key placement) are resolved.

---

## Final V4 sequencing (decided)

1. **Capability interfaces** (monitoring first) — the architectural change
2. **Monitoring-prometheus implementation** — proves the writeback pattern,
   contract-based per Luca, Prometheus-compatible
3. **Update the three charts** — switch from `monitoring.targets` to
   `capabilities.monitoring`
4. **Proof-of-concept combinators** — lightweight pipes (`withMetrics`,
   `withAutoscaler`) that transform resource bundles, no `_extraConfig`

---

## Deferred work (pick up later)

Everything below is explicitly deferred — not forgotten, just sequenced after
the working V4 migration. Each item includes why it was deferred and what
would trigger picking it up.

### Derivations + store-path naming

**What:** Replace attrsets with Nix derivations as the internal resource
representation. Resource names become content-addressed store paths. A `kix`
CLI would strip `/nix/store` prefixes and map hashes back to human-readable
names.

**Why deferred:** Luca says "this will need a LOT of learning still" and is
"happy if we skip it for the sake of getting to a working version quickly."
Derivations are frozen once built — can't merge with `//`, can't do capability
writeback during fixpoint. Fundamental architecture change.

**Trigger to pick up:** After V4 is working on attrsets and we're ready to
tackle the gitops/deployment pipeline (how compiled manifests get applied to
clusters).

**Luca's vision:** Derivations reflect dependencies via `runtimeDependencies`
to store paths. The DAG must be preserved. No explicit resource names — all
references go through the derivation graph.

### Refs / DAG / dependency tracking

**What:** A `ref` wrapper type for resource cross-references so typos become
eval-time errors. E.g., `serviceAccountName = ref "cert-manager"` would fail
if no resource named `cert-manager` exists.

**Why deferred:** Entangled with derivations (refs would wrap store paths in
the final version). Designing a temporary validation layer risks building
something that gets thrown away. Luca says "up to Adam, we can skip for now."

**Trigger to pick up:** When derivations land, refs become natural (they're
just store path references). Or earlier if cross-resource reference bugs become
a real pain point.

### RBAC DSL (intent verbs)

**What:** `kixlib'.rbac.dsl` with semantic verbs (`reconcile`, `own`, `emit`,
etc.) that expand to K8s RBAC verb lists. API group aliases (`cm`, `acme`,
`gw`). Pipe-based composition. See doc 10A for the full example.

**Why deferred:** Independent of the capability system. Additive improvement to
readability, not architectural. Current `mkRoleSet` + raw verbs works fine.

**Trigger to pick up:** Anytime after V4 ships. Could be a standalone PR.
cert-manager is the main beneficiary (8 ClusterRoles, ~200 lines of raw
verbs).

### Registry as capability

**What:** Replace hand-written `config.registry.coredns.endpoints.metrics` with
capability-driven computed FQDNs and typed ports.

**Why deferred:** Luca says "keep separate for now, handle through module
system eventually." The current hand-written registry works.

**Trigger to pick up:** When the capability system is proven and we want
service discovery to be type-safe and auto-computed.

### Full combinator framework (`_extraConfig` auto-declaration)

**What:** Combinators that both transform resource bundles AND automatically
declare capabilities. `withMetrics` would add a metrics port to the container
AND register `capabilities.monitoring.*` — zero manual capability declaration.

**Why deferred:** DSL design needs more iteration (Luca flagged metrics port
duplication and `enable` key issues in 10C). Building proof-of-concept pipes
first lets us validate the pattern before committing to the full framework.

**Trigger to pick up:** After proof-of-concept pipes are working and the
capability interface is stable. The design issues from 10C need to be resolved
first (single source of truth for port numbers, module system for enable/disable).

---

## Pre-implementation review (2026-03-09)

Three expert perspectives (Nix module system, K8s operations, migration risk)
reviewed whether the open questions are sufficiently answered to begin. Verdict:
**ready to start.** Two things to resolve before writing code; everything else
is discoverable during implementation.

### Resolve before writing code

**1. Capability submodule: nested output namespace (Luca's decision).**

The capability interface uses a single `types.submodule` with both input and
output fields. Charts write the input fields; implementation modules write the
output fields. Luca confirmed: **nested output, not a separate top-level path.**

```
capabilities.monitoring.<name> = {
  # INPUT — charts write these:
  port         : int
  path         : str        (default "/metrics")
  serviceName  : str
  selector     : attrsOf str

  # OUTPUT — implementation modules write these:
  output.labels      : attrsOf str
  output.annotations : attrsOf str
};
```

**Why this matters (critical context for implementation):**

The Nix module system evaluates options lazily, field by field. An
implementation module can safely read `target.port` and write
`target.output.labels` because they are independent evaluation paths — no
cycle. Infinite recursion would only occur if the implementation read from
`target.output` (its own output) to compute `target.output`.

**Rules to follow throughout the implementation:**

1. **Implementation modules must NEVER read from `.output.*` fields.** Reading
   your own output creates a circular dependency. The module system may not
   catch this at declaration time — it will manifest as infinite recursion or
   `infinite recursion encountered` errors at eval time. This is the single
   most important rule.

2. **Charts read output, never write it.** A chart may read
   `capabilities.monitoring.coredns.output.labels` to apply discovery labels
   to its resources. It must never write to `.output.*` — that's the
   implementation module's job.

3. **The submodule type declaration must include both input and output fields.**
   Luca noted this "might get complex with annotating that for nix properly" —
   the `types.submodule` definition needs to declare output fields with
   appropriate defaults (probably empty attrsets) so the module system knows
   about them before any implementation module runs.

4. **One implementation module per capability.** If two modules both write to
   `.output.labels` on the same target, the module system will either merge
   them (if using `mkMerge`) or one silently wins (if using `//`). For now,
   `monitoring-prometheus.nix` is the sole writer. If we later add
   `monitoring-datadog.nix`, they need explicit merge semantics.

5. **Don't name a target "enabled".** The capability interface is
   `attrsOf submodule`, so `capabilities.monitoring.enabled` would look like a
   target named "enabled" rather than a boolean switch. Cluster-level
   enable/disable switches must live at a separate path (e.g.,
   `monitoring.enabled`), not inside `capabilities.monitoring.*`.

6. **Implementation modules must NEVER read from `config.manifests` to produce
   entries in `config.manifests`.** This creates a fixpoint cycle — the module
   system tries to evaluate the manifests attrset to compute a new entry in
   that same attrset. Capability implementations should read from
   `config.capabilities.*` (the input declarations) and write to
   `config.manifests.*` (the output resources). One-directional flow:
   capabilities → implementation → manifests.

**2. Multiple targets per chart from day one.**

cert-manager has three monitoring targets (controller, webhook, cainjector) with
different ports, port names, and conditional enable gates. The capability
interface must be `attrsOf` (like the current `monitoring.targets`) — not
one-entry-per-chart.

### Implementation principles (agreed)

- **`withMetrics` reads the port from the container** — never takes it as a
  duplicate parameter. Luca flagged the 10C duplication as a design flaw.
- **Use `lib.recursiveUpdate` or `mkMerge` for writeback, never raw `//`** —
  shallow merge silently drops nested keys (Luca's `a // b` warning).
- **Don't normalize port names** — the three charts use `metrics`,
  `tcp-prometheus-servicemonitor`, `http-metrics`. Pass through existing names.
- **StatefulSet `serviceName` is immutable** — valkey's headless Service name
  must never be touched by combinators (pod DNS depends on it).
- **Update golden files after chart migration** — all 17 golden checks will
  break. Run `scripts/update-golden.sh`.

### Confirmed safe to proceed without

- Derivations — no module system traps with attrsets
- Refs — no dependency on capability work
- RBAC DSL — fully independent
- Registry as capability — orthogonal
- Chart isolation changes — flat layout continues
