## Trigger

Kix was never designed to model an ordering edge. Kix is designed to capture ALL information that can be known about a cluster before it is deployed. Making compilation possible in the first place. So 1 is more like the nix guarantee (and hence originally the language choice): If I have a resource X then I want to know EXACTLY what I need to make that resource work. This must not have false positives without destroying its core purpose - being the single source of truth. At the same time 1 allows all other constraints of the cluster like ordering or even network policies and dependencies derive from this information making a cluster definition no longer a folder of anible applied helm templates but instead something that can compile and guarantee down from the intent of end applicaitons.

## Reasoning

From first principles, in four steps:

**1. The primitive is a typed dataflow graph, not manifests-plus-context.**
Kix's real IR is wires: values flowing from producers to consumers, rendering into manifests at the leaves. Today the wires are untyped — every flowing value carries the same token kind ("identity of my producer"). So every reader must *guess meaning from identity* (edges.nix: "an identity in your context, and it happens to be a Service, so probably you dial it"). All the blindspots are downstream of untyped wires. The design move is the compiler-standard one: **type the wires, keep the channel.**

**2. Facts, with owners.**
A *fact* is a typed, content-addressed token riding the context of a value: `endpoint {selector, ports, ns}`, `credential`, `api-surface {port, caller=apiserver}`, `spawns {selector}`. Closed vocabulary, like the role registry. Then the architecture's core law, which follows directly from "closure captures what flows":

> Every knowable fact has exactly one owner whose job is to emit it as a value. If nothing can own it, it's a cluster axiom.

- `out.fqdn` owns the endpoint fact (the Service knows its selector/ports).
- The webhook *builder* owns "apiserver will dial me on 443" — spec-knowledge becomes flow at the authoring surface, not in an analyzer.
- The operator package owns `out.spawns` — the operand selector fact rides the CR instance into whoever consumes it.
- Whatever no resource can know (PSA, zones) is an axiom — 127 already built this tier.

This dissolves "make context smarter" as a category: gaps are never analyzer work, they are *unowned facts*, and the fix is always assigning an owner.

**3. Sealing = a typed node: absorb, terminate, or conduct.**
A seal decides, per fact kind, what happens to absorbed facts — one table, kind × fact:

- **Terminate**: workloads terminate endpoint facts (their pods dial; the fact becomes an obligation: egress hole, DNS wait, ordering).
- **Conduct**: ConfigMaps/Secrets re-emit absorbed facts on their own `out` — they carry, they don't dial. Indirection stops being a special case; it's the default behavior of a non-terminating node.
- **Emit**: producing your own facts on `out`.

Identity remains the one untyped fact every value always carries — that's the derivation record itself, sacred, maximal, never filtered.

**4. Interpreters become projections, not inferences.**
Ordering: project *all* facts (any derivation ⇒ exist-first). Netpol: project terminated endpoint + api-surface facts — the semantic leap disappears because the fact already *says* "dial." `kix explain`: project everything with provenance. The three hook phases survive untouched — they're about *when* fact sets are complete, orthogonal to what facts mean.

**What this costs, honestly:** `out` becomes a declared, typed surface (each field states its fact kind) — that's doc 120's "link-time typing of out contracts," which this design says is not a nice-to-have but the load-bearing change; everything else is mechanical. `edges.nix`'s registry-intersection heuristic gets deleted, not extended. `packageIntents` collapses into fact-minting. And 130 turns out to be the first instance of the pattern (endpoint fact, owned by the Service) — right move, one fact kind too early to see it was a vocabulary.

The whole design in one sentence: **one channel, typed facts with mandatory owners, seals as absorb/terminate/conduct nodes, readers as projections.**
