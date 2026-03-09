# 11: Open Questions Before V4 Refactor

What's blocking us from starting the V4 capability/combinator refactor, and
what's already decided.

---

## Decided (we can build on these)

- **Flat eval, not nested** — writeback wins
- **Combinators live in kixlib** — decision #3, "kixlib for sure"
- **Migration strategy: big bang** — Adam's call, decided
- **Monitoring: generic labels** — "find metric endpoints" not "find coredns"
- **Capability levels** — monitoring = cluster-level, autoscaling = application-level
- **config.manifests is terminal** — write-only, nothing reads from it

## Open questions that need Luca

### 1. Attrsets vs derivations (decision #1)

This is the biggest one. Luca's gut says "Nix native (derivations) + ref
interface" but also said it "feels still too big." The entire current
architecture is built on attrsets in `config.manifests` with deferred
serialization. Switching to derivations would be a fundamental change —
derivations are frozen once built, you can't merge into them, the `//`
operator doesn't work on them. The capability writeback pattern he loves
*depends* on attrsets being mutable during the fixpoint.

He might mean derivations only at the *output boundary* (after the fixpoint
resolves), not replacing attrsets throughout. But that needs clarifying because
it changes what you build.

**Status:** "Open — needs more clarity post-capability-migration." We could
punt this and build on attrsets (which work), then revisit.

### 2. The `ref` type system (part of decision #1)

Luca wants resource cross-references to go through a `ref` wrapper so typos
are eval-time errors. This doesn't exist yet and nobody's designed it.
Questions:
- Does `ref` wrap the resource name, the resource attrset, or a store path?
- How does it interact with string interpolation (e.g.,
  `serviceAccountName = "cert-manager"` becomes... what?)
- Does it need to work across charts (coredns referencing a cert-manager
  issuer)?

This is a design project in its own right. We could build V4 without it and
add refs later.

### 3. Registry as capability (decision #7)

The current `config.registry.coredns.endpoints.metrics` is a hand-written
attrset. Should it become a capability interface (computed FQDNs, typed
ports)? Luca said "keep open, revisit after migration." This affects whether
charts declare their service endpoints through the capability system or
separately.

### 4. Chart isolation mechanism (decision #4)

"Current or submodules" — Luca leans toward convention-based isolation (what
we have now) but said to "reasked with more clarity." Do we build capabilities
assuming the current flat `services.<name>` layout, or do we structure them
for a future move to `charts.<name>` submodules? The migration from one to the
other is mechanical (the research says so), but it's nice to not paint
ourselves into a corner.

## Open questions that are ours to decide

### 5. Capability interface shape

The research sketched `capabilities.monitoring.<name> = { port; path;
namespace; serviceName; }` with output fields `{ labels; annotations; }`. But
the exact option types, defaults, and submodule structure haven't been nailed
down. Specifically:
- Does each chart get a named entry (`capabilities.monitoring.coredns`) or
  does a chart declare multiple entries
  (`capabilities.monitoring.coredns-controller`,
  `capabilities.monitoring.coredns-webhook`)?
- What's the minimal interface that works for both Prometheus and Datadog?

### 6. RBAC DSL scope

Luca's example (10A) shows what the DSL *looks like*, but not how it's
implemented. The intent verbs (`reconcile`, `own`, etc.) need concrete
implementations in kixlib. Do we build this as part of V4 or after? It's
independent of the capability system — we could ship it separately.

### 7. Combinator implementation details

The `_extraConfig` accumulation pattern (combinators stash capability
declarations in a hidden field, `mkChartModule` extracts them) is sketched but
not built. Edge cases:
- What if two combinators write to the same capability path?
- How does `optionalPipe` interact with `_extraConfig` when the condition is
  false?
- Does `mkServiceDeployment` replace `mkChartModule` or work inside it?

## Recommended sequencing

We could start building **now** with what's decided. The critical path is:

1. **Capability interfaces** (monitoring first) — this is the architectural
   change
2. **Implementation modules** (monitoring-prometheus) — proves the writeback
   pattern
3. **Update the three charts** — switch from `monitoring.targets` to
   `capabilities.monitoring`
4. **Combinators** — `withAutoscaler`, `withPDB` in kixlib
5. **RBAC DSL** — independent, can happen in parallel

Items 1-3 are the big bang. Items 4-5 are additive improvements after the core
pattern works. The open questions (refs, derivations, registry-as-capability)
can all be deferred — they layer on top without invalidating the capability
work.

## The one thing to settle with Luca first

**Decision #1** (attrsets vs derivations). Not because we need derivations now,
but because if he comes back after the migration and says "actually I want
derivations throughout," we'd be ripping out what we just built. A quick "we're
building on attrsets, derivations are a future layer at the output boundary,
yes?" would derisk the whole effort.
