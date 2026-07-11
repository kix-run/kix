# 131: Fact kinds — remainders and operand attribution

**Status:** Draft (attribution question under active discussion)
**Related:** `97_service_contract_primitives.md` (Phase-2 service DSL), `92_declarative_network_policy_intents.md`, `95_netpol_build_time_validation.md`, `121_netpol_as_plugin.md`
**Supersedes:** `archive/130_typed_network_exposure.md` (S1 mechanism + operand termination shipped as the typed-facts channel, PR #31), `archive/96_netpol_autogeneration_blindspots.md` (blindspots 1–2 closed by fact conduction; blindspot 3 partially closed by factBehavior)

What shipped (PR #31, not re-argued here): the typed-facts channel
(`core/facts.nix`) — endpoint facts on address-shaped `out` fields,
conduct/terminate at seals, ConfigMap/Secret indirection by default,
edge analysis on fact readback, `refOnly`/`connect` escapes, and
`factBehavior` on `mkCRD`/`mkCRDRef` (terminate-declared CRs → operand
egress + caller-ingress) with `cluster.factBehavior` as override and
builder-less fallback. 130's taxonomy (§0) remains the requirements
map; its case numbers are cited below.

This doc carries the two things still open: the **next fact kinds**
(mechanical, roadmap-shaped) and the **operand attribution question**
(a real design tension, §2).

## 1. Remainders from 130, recast as fact kinds

Each of these is "a knowable fact that doesn't yet flow" — per the
design law, the fix is assigning an owner that mints it, never a
smarter analyzer.

- **`api-surface` (S2, 130 §6.1)** — "the apiserver/host will dial me
  on port P." Owner: the builder that creates the webhook config /
  APIService / probe'd workload (`scope.mkWebhookService`, `mkCRD`
  webhook wiring). Blocked on enforcer envelope work: a
  `fromEntities=[kube-apiserver,remote-node,host]` **ingress** builder
  and an ingress supplement-emit path (today's supplements are
  egress-only). Biggest confessed gap of the shipped validation.
- **Probe ingress / NodePort / LB scoping (S3, 130 §6.2)** — derive
  host-ingress from probe fields; extend external-ingress to NodePort;
  scope world-ingress to the LB's backing pods. Same envelope
  prerequisite as api-surface.
- **External connects (S4, 130 §6.3)** — `connect` descriptors for
  P3/P4/P5 (`{fqdn}`, `{cidr}`, `{entity}`) folding into
  `packageIntents`' slot; envelope grows `toCIDR`/`toFQDN` (allow-side
  only — the deny axis stays deferred to `interesting_thoughts/` per
  130 §9).
- **Phase-2 service DSL (97)** — unify kix-managed and
  externally-backed Service `.out` through the same
  autoOut+fact machinery; retires `mkServiceRef`'s single-path hack.
- **Locking test: role-resolved reads preserve facts** — verify
  `out.fqdn` survives `eval/roles.nix` resolution with fact context
  intact (130 §9 flagged; the facts rework changed the mechanism, the
  test is still unwritten).
- **Baseline operand fabric (130 §6.4, the un-shipped half)** — see §2.

## 2. The open question: operand attribution

### 2.1 What shipped, and the accident it relies on

`factBehavior` terminate answers: *"endpoint facts absorbed by this CR
are dialed by pods matching `podSelector cr`."* This works because of
a directional property of the stackgres case: **the pod-owning CR is
the one that absorbs the fact.** SGObjectStorage (carries the S3
endpoint) is *referenced by* the SGCluster (owns the operand pods), so
conduction delivers the fact to the CR whose declaration can name the
dialers. Attribution rides the value-flow direction.

### 2.2 The tension

**Facts flow along value edges; dialing responsibility flows along
controller semantics — and the two directions do not always agree.**

The co-directional pattern (root CR aggregates config, references
carriers by value) is the dominant operator idiom and is fully served.
The counter-directional pattern is *selection*: the endpoint-carrying
CR is **watched or label-selected** by the dialer, so no value ever
flows from it to anything that terminates. Real cases:

- **AlertmanagerConfig** embedding a webhook URL — dialed by
  alertmanager pods, which *select* the config CR; nothing absorbs it.
- **ServiceMonitor** — the scrape edge's `from` (Prometheus pods) is
  not in the ServiceMonitor at all (130 §6.1 flagged this for S2).
- Middleware/route CRs (Traefik, Gateway API extensions) — data-plane
  pods select the CR.

For these, the endpoint fact dead-ends in a CR that nothing
terminates: today's outcome is the unknown-kind warning and no hole —
fail-closed, visible, but unresolved.

A second, smaller tension: **attribution is node-level.** One CR
absorbing two endpoints attributes both to one podSelector. If a kind
ever has endpoint A dialed by operands and endpoint B dialed by a
different pod set, the declaration can't split them.

### 2.3 Approach (proposed, under discussion)

Three tiers, matching how determinable the dialer is at eval time:

1. **Co-directional — done.** Conduction + terminate declaration.
   Evidence: stackgres. No further mechanism.
2. **Counter-directional with a *static* dialer — small extension, not
   a new model.** For watch-based kinds the dialer is a fixed workload
   of the operator instance (alertmanager pods, prometheus pods), so
   the CRD owner can declare terminate with a **static** podSelector —
   already legal in the declaration shape. Two genuine gaps:
   - `podNamespace`: the dialer's pods live in the *operator's*
     namespace, not the CR's; the operand-CNP emit currently parents
     into the CR's namespace. The declaration needs an optional
     namespace (or "the declaring instance's namespace" as default for
     static selectors).
   - the caller-ingress side must use that namespace too.
   This tier also naturally hosts the ServiceMonitor scrape case: the
   monitoring package declares the scraper's selector once.
3. **Dynamic dialers — refuse, warn, escape-hatch.** Kinds whose
   dialer is determined per-CR by runtime selection results have no
   eval-time answer (130 §6.4's residue). Keep the warning;
   `cluster.factBehavior` with a hand-written selector is the operator
   escape. Do not build speculative machinery.

The per-endpoint split (second tension): extend `podSelector` to
optionally receive the fact (`podSelector = cr: fact: ...`) **only when
a real package demands it** — cheap to add later, wrong to pre-build.

**Deliberately not proposed:** a `podSet` fact minted onto CRs (the
130-era idea). Tier 2 covers the known real cases with one field;
a full join of podSet×endpoint facts at eval time adds a second
attribution mechanism before any case requires it.

### 2.4 Relationship to the baseline fabric (130 §6.4)

The `scope.operatorOperand` primitive 130 ruled (operator→operand
reconcile, operand↔operand self-rules, DNS+apiserver for operands) is
**orthogonal to attribution** and remains un-shipped: stackgres still
hand-rolls it. It is endpoint-fact-independent (the operand fabric
exists even with zero absorbed endpoints), so it stays a separate
primitive — plausibly `factBehavior` grows a `fabric = true` flag that
emits the baseline set alongside termination, replacing the
stackgres hand-roll entirely. Open: whether that flag belongs in the
same declaration or a sibling.

## 3. Open questions (discussion 2026-07-11 ended here — unruled)

0. **Foundational: is the directional-accident framing sound?** Tier 1
   works because reference direction happens to align with dialing
   responsibility in the aggregate-config idiom. Claim: not an
   accident — the pod-owning CR *is* the config root by operator
   design convention. If that's survivorship bias from one stackgres
   example, the rejected `podSet` fact comes back on the table.
   Falsifier to look for: a real operator whose pod-owning CR is
   *referenced by* the endpoint-carrying CR by value.
1. §2.3 tier 2: `podNamespace` field vs "declaring instance's
   namespace" default — and does the static-selector case deserve a
   distinct name in the declaration (`dialedBy`?) to keep
   terminate-by-operand and terminate-by-watcher legible as different
   claims? (Lean: separate field — "who dials" and "which of my
   operands dial" are different sentences.)
2. §2.4: baseline fabric as `factBehavior.fabric` flag vs separate
   `scope.operatorOperand` primitive. (Lean: the flag — the
   declaration already names the operand pod set; two surfaces
   describing the same pods invites drift.)
3. `api-surface` fact kind: mint at which builder(s), and does the
   envelope ingress work land with it or before it?
4. Chase/auto-attribution flip (130 §4.1/§9): with conduction now
   default, is the mount-helper chase-lint still needed, or does the
   observed-vs-declared lint subsume it? (Suspicion: subsumed —
   verify against a helm-heavy cluster.)
