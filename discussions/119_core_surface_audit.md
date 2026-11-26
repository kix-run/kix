# 119: Core surface audit — readiness × necessity of the authoring ideas

**Status:** Draft
**Related:** `guide/00-ideas.md` (evaluation subject), `100_package_dsl_ergonomics_survey.md` (inverse lens: what's missing), `29_compiler-design.md`, `66_milestone_roadmap.md`, `58_satchel_mvp_technical_requirements.md`

## Purpose and lenses

The guide's ideas doc (`guide/00-ideas.md`) states 11 principles behind the authoring API. This doc audits each against what `kix/lib` actually implements today, on two axes:

- **Readiness** — how baked the mechanism is: `core` (is the compiler), `ready` (complete, proven in packages), `beta` (complete but with known gaps/assumptions), `alpha` (implemented, unproven — little or no real usage), `poc`.
- **Necessity** — measured against two nested targets:
  - **Lens A: minimal open-sourcable package DSL.** The smallest surface a package author needs.
  - **Lens B: minimal compiler pitch.** The smallest surface that delivers "verifiable cluster artifact: define → evaluate/check → preview → deploy" end to end. Lens A exists to serve Lens B.
  - Ratings: `essence` (the pitch is this), `core` (minimal DSL needs it), `layer` (opt-in ring on top), `questionable` (unproven value, cut candidate for the core).

Both lenses are read **from the package author's seat**, which is also the ideas doc's vantage point: for each mechanism, what does the author have to *do* to make their package compiler-ready, and what do they get back for it? A mechanism that is elegant internally but raises the authoring burden without a matching payoff is a layer, not core — and vice versa: a mechanism the author cannot opt out of without breaking the artifact is essence regardless of its internal weight.

**Evidence base:** `kix/lib` source scan (netpol, scorecard+rules, helm+helm-dag, rbac, crd), a usage census over all 60 packages in `kix/packages/` plus cluster definitions (`clusters/`, `ludo/`, `nw1-migrated/`), and the guide reference (01–03), which is current against the code.

## Headline findings

1. **The essence is four ideas and they are done.** Store-path-as-edge (4), compiler framing (1), K8s-shaped (6), and rich `out` objects (7, minus `url`/`ports`) form one mechanism in `k8s.nix` + `eval/` — mature, CLI-contracted, and used by every package. This is the irreducible artifact story.
2. **Several flagship examples in the ideas doc have zero real usage.** `scope.mkOptional` (cited in idea 2) — 0 packages. `scope.mkWebhookService` — 0. `kix.monitor` — 0 (packages hand-roll via `prometheus.out.mkServiceMonitor` instead). `out.url` / `out.ports` — 0. The ideas doc describes the *intended* surface; the practiced surface is smaller.
3. **The derivation showcase (netpol) is the least neutral subsystem.** Enforcer interface exists but the CNP spec envelope is hardcoded Cilium (`netpol.nix:298-350, 522-556`; `portsToCilium` in the "neutral" interface). It is a layer, not essence.
4. **The discipline enforcement is off by default.** The scorecard rules that police the essence (`selectorCoherence`, `fqdnWithoutContext`) require opt-in. The ideas doc's closing claim — "the scorecard enforces the discipline rather than leaving it to convention" — is currently only true for clusters that enable it.
5. **The authoring contract is genuinely small — one habit plus one convention.** Everything the compiler needs from an author reduces to: reference siblings through `out.*` (never literals), and name a `root`. The rest of the mandatory surface (typed options, `selectorLabels`, deps-as-args) is either standard Nix-module practice or a one-line idiom. The burden is not the contract; it's the sharp edges around it (see the authoring-contract section).

## The authoring contract — what a package author must do, and what they get

The ideas doc is written from this seat, so the audit needs it explicit. Split into obligations (compiler-ready or it breaks), idioms (strongly pushed, checked when violated), and affordances (available, optional).

### Obligations — the mandatory contract

| Obligation | Author cost | What it buys | Verdict |
|---|---|---|---|
| Return `{ build }` with named parts and a `root` | one convention | entry point, readiness anchor, forward closure | essence |
| Reference siblings/deps via `self.x.out.*` / `dep.out.*`, never literals | **the one habit** | the entire DAG: ordering, waves, netpol, closure — for free | essence |
| `requires`/`extraDeps` for edges with no flowing value | rare, explicit | closes the gap the habit can't cover | essence |
| Build workloads through `scope.mk*` constructors | none vs raw attrsets (pipe-friendly) | validation, labels, namespace, netpol emission | core |
| `spec.selector.matchLabels` (use `scope.selectorLabels`) | one line | selector coherence, service derivation | core |
| Declare deps as `build` args (`postgres ? null`) | zero — it's a function arg | DI resolution, auto-wiring, netpol service registry | core |
| Type options with `lib.mkOption` | standard Nix-module practice | typed config, cluster overrides, defaults | core |
| Fix structural warnings (orphans, redundant requires) | reactive | catches half-wired resources at eval | core |

Honest total: a compiler-ready package is the ~15-line `banner` example. The essence asks **one habit** (out-references) that has no analogue in Helm/Kustomize — and it's also the single thing every downstream promise (ordering, netpol, blast radius) depends on. This asymmetry (tiny contract, everything derived from it) *is* the DSL's pitch to the author and deserves to be stated that way in the guide.

### Sharp edges — where the contract leaks onto the author

These are the places the author pays for compiler internals. For an OSS core, each is either sanded, loudly documented, or a reason to hold a surface back:

- **`.name` vs `.out.name` on StatefulSet `serviceName`** — wrong pick = infinite recursion, no error message pointing at the cause. Worst edge in the surface; the `headlessService` shorthand exists but the failure mode remains reachable.
- **`rawSelector` cycles** — the author must understand eval-order internals to know when `out.selector` will recurse. Escape hatch exists, but diagnosing the need for it requires compiler knowledge.
- **Non-string leaves carry no context** — an int port "dependency" silently drops the edge; only a trace warning.
- **3-level `collectTypedAttrs` depth** — resources nested deeper silently vanish from the deploy.
- **`anything`-typed deep-merge caveat + `global` must be declared by every package** — module-system semantics leaking through as hard errors or silent drops.
- **`clusterConfig.cluster.domain` latent gap** — three packages and `kix.expose` read an undeclared option that is always `null`.
- **Phase-1 vs phase-2 split** — dep-touching code outside `build` throws; the error is clear but the *reason* (two-phase calling) is compiler internals the author shouldn't need.

None of these invalidate the contract; together they are the gap between "the contract is small" and "the contract feels small." Sanding this list is higher-leverage for an OSS core than adding any Ring-2 feature.

### Affordances — what's on the shelf, by author payoff

The census reorders the shelf by what authors actually reach for: `scope.mkResource`/`mkDeployment` (56/31 packages), `kix.port` (21), `service.fromWorkload` (15), `scope.rbac` (16), mounts (9), `expose` (10), `importChart` (9). That *is* the practiced core DSL. The unused shelf (`mkOptional`, `mkWebhookService`, `monitor`, `out.url`, `ingress.fromService` directly) tells the same story from the other side: authors default to the smallest surface that satisfies the contract, and reach for helpers only when a validator or a real bug pushes them. Design consequence: **grow the core DSL from the census, not from the survey** — doc 100 proposes what could help; the census shows what did.

## The DSL, classified — grammar vs vocabulary

"The DSL" is not one kind of thing. Sorting every authoring surface in `kix/lib` by what role it plays yields ten word-classes, and they split cleanly into a closed **grammar** (the words that interact with the graph — remove one and packages stop being compiler-ready) and an open **vocabulary** (words that make authoring safer or shorter — remove one and packages get longer, not broken).

### Axis 1: role in the language

**Grammar (closed set — this is the core DSL):**

| Class | Words | Why grammar |
|---|---|---|
| **Sealants** | `scope.mkResource`/`mkClusterResource` (and every wrapper that ends in them: `mk<Workload>`, `mkSecret`, `mkCRD`, `importChart`'s wrapping) | the only way to mint a graph node; nothing exists without one |
| **Queries** | `out.*` (name, fqdn, selector, identityHash; secret `keyRef`/`mkEnv`; crd `cr`/`mkCR`) | reading *is* edge-writing (idea 4); the contract surface between resources and packages |
| **Edge words** | `requires`, `extraDeps`, `root.{requires,postHooks}`, `installedBy`, `extraEdges` | explicit graph edits where no value flows |
| **Boundary markers** | `mkImport`, `mkSecretRef`, `mkCRDRef`, `kix.untrackedRef` | give things kix does not own a graph identity, so the closed-world graph can reference the open world |
| **Composition forms** | `self` fixpoint, build-list entries, DI args, `mkParts` | how words combine into packages and packages into clusters |

**Vocabulary (open set — grows by demand):**

| Class | Words | Character |
|---|---|---|
| **Fragment builders** | `kix.port`, `mkEnvVars`/`mkEnv`, `mount.*`, `kix.options.*`, `parseGi` | pure values, no graph interaction; classic code-savers |
| **Derivers** | `service.fromWorkload`, `ingress.fromService`, `httpRoute.fromService` | sealed resource → new pre-seal spec; consistency by derivation (a derived selector *cannot* mismatch) |
| **Injectors/transformers** | `withMounts[On]`, dep-provided `out.withCert`, `patchResources` | pre-seal spec → pre-seal spec |
| **Sub-DSLs** | rbac pipes (`grant`/`watch`/`reconcile`), crd pipes (`fromKind \|> withSchema`), `meta.network.intents` | a domain language compiling intent to a correct K8s shape — idea 2's "abstraction" case |
| **Behaviors** | `kix.expose`, `kix.monitor` | build-list entries carrying their own DI deps; contribute whole resource sets |
| **Escape hatches** | `rawSelector`, `extra`, `strip`/`preserveAnnotationPrefixes`, `selectorLabels` override | deliberate contract violations, each meant to trip a visible check |

### Axis 2: guarantee class — refining idea 2's binary

The ideas doc sorts features into abstraction vs code-saver. The code suggests a finer spectrum, and it predicts adoption better:

- **G0 — contract**: required for graph membership (sealants, queries, edge words). Not optional.
- **G1 — correct by construction**: the mistake class is *unrepresentable*. `fromWorkload` (selector always matches), secret key contracts (typo throws at the use site), rbac intents (a "reconcile" verb-set can't be mistyped), mount namespace markers, `headlessService` shorthand.
- **G2 — checked after construction**: mistake representable, caught at eval (the validator catalog, `extra`-shadow guard, intent schema validation).
- **G3 — pure code-saver**: no new guarantee (`kix.port`, `mkEnvVars`, options bundles).
- **G4 — policy**: opt-in judgment (scorecard rules).

**The census validates the spectrum.** G1 vocabulary gets adopted: `fromWorkload` 15 packages, `scope.rbac` 16, mounts 9. G3 survives only when universal (`kix.port` 21, `mkEnvVars` 10) — niche G3 dies (`parseGi` 1). And behaviors beat their underlying derivers: `kix.expose` (10) fully absorbed direct `ingress.fromService` use (0) because it bundles the deriver with the DI decision the author didn't want to make. The zero-usage shelf (`mkOptional`, `mkWebhookService`, `monitor`) is all vocabulary that added a *concept* without adding a guarantee an author was missing that week.

### Design rules that fall out

1. **Keep the grammar closed and small.** Every grammar word is essence or core in the ring model; a proposal that adds a grammar word (a new way to create nodes or edges) needs the highest bar. Vocabulary can grow freely — by the demand test.
2. **Push vocabulary up the guarantee spectrum.** A helper earns core-DSL placement by being G1, not by being short. If a proposed helper is G3, it must be universal to ship (the `kix.port` test).
3. **Behaviors are the delivery vehicle for cross-cutting vocabulary.** When a helper needs a DI decision (which ingress? which prometheus?), wrap it as a behavior; naked derivers for those cases go unused.
4. **Sub-DSLs only where K8s fights the author** (rbac verb soup, CRD boilerplate) — and they must compile to inspectable standard shapes (idea 6). Both existing sub-DSLs pass; `meta.network.intents` passes because the graph genuinely cannot see those edges.
5. **Every escape hatch trips a visible check** (`rawSelector` → `selectorCoherence`). An escape hatch without an alarm is a silent contract break — this is the concrete form of refusal law 1.
6. `mergeFragments` (`fragments.nix`) is grammar for *clusters*, not packages (multi-team composition with collision detection) — Ring 3 today, but it's the seed of the doc-45 federation story and worth keeping small and stable.

## Per-idea audit

### 1. Kix is a compiler; authoring is source — readiness: **core** · necessity: **essence**

The eval pipeline (`eval/cluster.nix` fixpoint, Activation-rooted closure, `mkManifests`) *is* this idea. Nothing to cut; everything else in this doc is judged by how much it serves this.

The compiler analogy extends further than the ideas doc states: **flavors are the target definition** — the x86-vs-ARM of this compiler. `cluster.capabilities` is the instruction set (validators refuse a DaemonSet for a target without one, exactly as a codegen pass refuses an unsupported instruction), and shadowable platform imports are the ABI (the dns/storage/ingress symbols every target must provide, resolvable by the platform or overridden by a managed instance). This makes the flavor *mechanism* part of the compiler core; the ideas doc should say so.

### 2. Every feature answers one of two questions — readiness: **n/a (process)** · necessity: **essence as governance**

A design filter, not code. Keep it as the contribution bar for an OSS core — it's the best defense against surface creep. But note: the filter's own showcase examples failed the demand test. `scope.mkOptional` and `mkRoleSet` shipped from doc 100's survey; `mkOptional` has 0 package usages, `mkRoleSet` 5. The filter answers "should this exist," not "does anyone need it yet." For the core, add a third question: **has a package actually asked for it twice?**

### 3. Automation over brevity — readiness: **ready** · necessity: **core** (channel: **essence**)

The validator set in `eval/scope.nix` is real and complete: selector-subset, namespaced-ref tracking (throws on untracked/cross-ns Secret/ConfigMap/PVC/SA refs), named ports, `limits >= requests`, duplicate names, fieldRef paths, capability gates. Each traces to a real bug class. Split for the core:

- The **eval-time diagnostics channel** (throw/warn with instance attribution, structural warnings after fixpoint) is essence — it's the "evaluate/check" leg of the pitch.
- The **catalog** is core and extensible; individual validators are cheap, well-scoped, no cuts needed.

### 4. Store-path = DAG edge — readiness: **core** · necessity: **essence**

`k8s.nix` (`toFile` hashing, context readback, `kix.dev/depends-on`, `requires`/`extraDeps` folding, Activation closure) is mature and is the CLI's contract. The single differentiator; everything the pitch says about "verifiable artifact" and derived ordering cashes out here.

Known cost, honestly held: a hardcoded string silently drops an edge. Mitigation is two-tier: `checkNamespacedRefs` *throws* for the dangerous ref classes (core, always-on), scorecard rules *warn* for selectors/FQDNs (opt-in — see idea 12 note under scorecard).

### 5. Ask for a role, not an instance (DI) — readiness: **ready (core ladder) / beta–alpha (outer rings)** · necessity: **core / layer / questionable** by ring

The resolution core (`eval/resolve.nix`: build-arg introspection, `? null` optionality, priority ladder, aliases, managed-shadows-imports, ambiguity throws) is mature and load-bearing for every multi-package cluster. **Core.**

The outer rings are progressively less proven:

| Mechanism | Readiness | Necessity | Evidence |
|---|---|---|---|
| Named-arg DI + aliases + `mkImport` | ready | core | universal; `mkImport` in flavors + satchel/ludo clusters |
| Auto-instantiation (`eval/auto.nix`) | beta | layer | works, great demo; adds resolution opacity; only required deps drive it |
| Dep config injection (`deps.<x>.config`) | beta | layer | real users (immich→stackgres); powerful but the most "magical" flow in the system |
| `mkLocked` | alpha | layer | 0 usages found outside lib |
| `optional = true` instances | alpha | layer | flavor/platform-import pattern only |
| `kix.mkEnv` env stamping | alpha | **questionable** | 4 refs; shallow-merge gotcha documented; guide itself recommends hand-written prefixed instances for deep semantics |

### 6. Stay K8s-shaped — readiness: **ready** · necessity: **essence**

Not just a slogan — enforced: `extra` cannot shadow managed fields (throws), `mkResource` takes real `apiVersion/kind/spec`, helpers emit standard fragments. This is what keeps the artifact `kubectl apply`-able and the pitch's interop claim honest. Zero maintenance cost; keep absolute.

### 7. Resources are rich objects (`out`) — readiness: **ready / alpha** split · necessity: **essence / layer** split

`out.{name, fqdn, selector, identityHash}` — ready and essence: `out.name` in 45/60 packages, `out.selector` 15, `out.fqdn` 10, `identityHash` 5 (checksum-restart idiom). `out` is the ergonomic carrier of idea 4; without it, edges would ride on `"${resource}"` store-path interpolation.

`out.url` and `out.ports` — **alpha, 0 usages anywhere**. Built ahead of demand (doc 31/97 direction). Keep behind the `mkServiceRef` shape-compatibility argument or demote to the port-DSL design doc until a consumer exists.

### 8. Three things the DSL refuses to do — readiness: **ready** · necessity: **essence**

The refusals are encoded, not aspirational: ambiguity throws in `resolveArg`, `kix.expose` throws on dual ingress deps, no inferred exposure/monitoring. Costs nothing; it's what makes derivation trustworthy. Keep as hard law for the core.

### 9. Declare intent, derive mechanism — **split verdict**, the most important one in this audit

Three derivations hide under one idea, at very different maturity:

- **Deploy waves from the store DAG** — readiness: core; necessity: **essence**. This is "the compiler derives ordering," the pitch's beating heart. Done (CLI walks the Activation closure).
- **Selectors/labels from the workload** — readiness: ready; necessity: core. Small, universal (`scope.labels` stack, `service.fromWorkload` in 15 packages).
- **Network policy from the graph** — readiness: **beta**; necessity: **layer**. Working and sophisticated (per-workload CNPs pre-`toFile`, SA→Binding walk for api-server egress, default-deny), but:
  - Cilium-specific in practice: the CNP envelope is hardcoded despite the enforcer interface; the interface itself leaks (`portsToCilium`).
  - Blind spots are structural, not incidental (doc 96): Helm opacity, hostNetwork, context-free FQDNs, LB-only external ingress.
  - It is the flagship *demo* of the thesis, not the thesis. The minimal compiler pitch survives without it; a security-conscious adopter gets it as the first big opt-in layer.

### 10. Capabilities have owners — readiness: **alpha** · necessity: **layer, arguably questionable for the core**

The mechanism is elegant (annotation-stamped DI builders, fingerprint rule) but thin: 2 fingerprints (storage, reflection), and policing requires scorecard opt-in. `provides` is used in 23 packages, but dominantly for the enforcer lookup (a netpol need), not general capability contracts. This is multi-team governance — real value at org scale, premature for a minimal core. Keep the annotation convention; defer the rule library growth to demand (doc 83b direction).

### 11. Compose by adding behaviors — readiness: **ready (mechanism) / mixed (behaviors)** · necessity: **core (mechanism) / layer (behaviors)**

- The **build-list mechanism** (per-entry dep discovery, unioned deps, `//`-merged parts) is small, clean, and used by 10/60 packages. Core — it's also what makes DI composable.
- `kix.expose` — ready, layer: 10 packages, the DI-dispatch (gateway vs ingress) is proven.
- `kix.monitor` — **alpha, 0 usages, superseded in practice**: every real package calls `prometheus.out.mkServiceMonitor` directly (the owner-builder pattern of idea 10 won). Doc 110 moves alerts elsewhere too. Cut candidate in current form.

## Beyond the 11: the rest of what `kix/lib` can do

| Surface | Readiness | Necessity | Notes |
|---|---|---|---|
| Helm import, 3 tiers | beta | layer (adoption-critical) | 9 packages on Tier 2; Tier 1 used cluster-side (ludo, nw1-migrated). DAG inference: 9 patterns, but namespace-blind (Kind/name keys), missing PVC/webhook/CRD→CR edges; external-dep edges silently dropped (`helm.nix:591`). Not core to the pitch, but the #1 migration on-ramp (doc 116). |
| Secrets: `mkSecret`/`mkSecretRef` | beta | core-leaning layer | Key-declared validation is a genuine abstraction (typos fail at eval); SOPS deploy-time hydration still landing (doc 77b). A real deployment needs *some* secret story; the ref/marker mechanism is the part worth keeping in the core. |
| RBAC pipe DSL | ready | layer | Complete, no TODOs; 16 packages use `scope.rbac`. Pure code-saver — could live as a library beside the core, not in it. |
| CRD builders (`crd.nix`, `mkCRD`/`mkCRDRef`) | ready-with-limits | layer | Complete but single-version-shaped; permissive schema by default (no validation unless `withSchema`). 4+4 usages. The `mkCRDRef` marker + `installedBy` gating is the valuable, kix-specific part. |
| Scorecard engine + 18 rules | ready (engine) / seed (library) | layer — with one carve-out | Engine is mature (severity chain, 4 levels, no placeholder rules). **Carve-out:** `selectorCoherence` + `fqdnWithoutContext` police the essence (idea 4's silent-edge cost); consider promoting them to always-on diagnostics (doc 80 channel) instead of opt-in policy. |
| Overrides: `partsOverlays`/`globalPartsOverlays`, `labelStyle`, `selectorLabels` | alpha | layer (migration-driven) | 1 usage (a test cluster) in-tree; designed for live-cluster adoption (nw1). Keep minimal; these are operator escape hatches, not authoring surface. |
| Flavor **mechanism** (capabilities, shadowable platform imports) | ready | **core — the target definition** | A flavor is the compiler's machine surface: `cluster.capabilities` is the instruction set the validators compile against (`checkDaemonSet`, `checkLoadBalancer`, `checkPrivileged` are target-gated codegen checks), platform imports are the ABI (dns/storage/ingress symbols the linker resolves, shadowable by managed instances). A K8s compiler without a target model can't claim "know what will happen" — the same package legitimately compiles differently for GKE Autopilot than for kind. Belongs in Ring 1. |
| Flavor **backend catalog** (12 profiles) | alpha breadth | questionable breadth | kind/k3s/lithus are exercised; eks/gke/gke-autopilot/aks/openshift/rke2/talos/scaleway/ovh are unvalidated files — like a compiler listing backends it has no tests for. Prune or mark experimental for an OSS core; the mechanism stays regardless. |
| `scope.mkWebhookService` | alpha | questionable | 0 usages. Cut or keep dormant until an operator package adopts it. |
| `scope.forNamespace` | ready | core (internal) | 6 usages; also load-bearing inside netpol's paired-ingress emission. |

## The ring model (proposed shape for an open-sourcable core)

- **Ring 0 — the artifact (essence, non-negotiable):** `mkResource` + string-context machinery + `out.{name,fqdn,selector,identityHash}` + `root`/`requires`/`extraDeps` + `self` fixpoint + `collectTypedAttrs` + PackageInstance/Activation closure + the diagnostics channel + the refusal laws (ambiguity throws, extra-shadow throw). Ideas 1, 4, 6, 7-core, 8.
- **Ring 1 — checked authoring (core DSL):** workload constructors + validator catalog + options/config module eval + DI resolution ladder + `mkImport` + namespace handling + build-list composition + label stack + the **flavor mechanism** (capability instruction set, platform-import ABI — the target definition the validators check against). Ideas 3, 5-core, 11-mechanism.
- **Ring 2 — derived & imported (opt-in layers):** netpol derivation (cilium module), Helm import, secrets, CRD/RBAC DSLs, `kix.expose`, scorecard engine + rule library (minus the two essence rules if promoted).
- **Ring 3 — scale & governance (demand-gated):** capability ownership fingerprints, dep config injection, `mkLocked`, auto-instantiation, `mkEnv`, flavor breadth, monitoring wiring.

The pitch demo needs Ring 0 + Ring 1 only: define a package, get told at eval you're wrong, preview the artifact + DAG, deploy in derived order. Everything in Rings 2–3 strengthens the story but none of it is the story.

## Cut / demote candidates (explicit)

1. `kix.monitor` — superseded by owner-builder pattern; 0 usages. Remove or rewrite per doc 110.
2. `out.url` / `out.ports` — 0 usages; park in the port-DSL design (doc 31) until a consumer exists.
3. `kix.mkEnv` — 4 refs, footgun merge semantics, documented better alternative. Demote to recipe or remove.
4. Unvalidated flavor *backends* (8–9 of 12) — prune to the tested set or mark experimental. The flavor mechanism itself is core (target definition) and untouched by this.
5. `scope.mkWebhookService`, `scope.mkOptional` — adopt in ≥2 real packages within a milestone or demote from the guide/ideas doc to "available, unproven."
6. `mkLocked` — keep (tiny), but stop featuring it until dep-injection conflicts occur in practice.

## Open questions

- **Promote the two essence-policing scorecard rules to always-on?** They guard idea 4's known failure mode; leaving them opt-in contradicts the ideas doc's closing claim. (Rides doc 80's diagnostics.)
- **Does netpol ship in the OSS core at all**, or as a separate cilium-flavored module until the enforcer interface stops leaking? (Docs 92, 96.)
- **Adopt-or-demote deadline for zero-usage helpers** — who decides, and does the guide get corrected to describe the practiced surface rather than the intended one?
- **Is Helm import Ring 2 or Ring 1 for adoption purposes?** The pitch doesn't need it; the migration playbook (116) treats it as the default on-ramp. The OSS core's first external user probably arrives via Helm.
- Idea 2's filter needs the demand test added (feature ships only after a second real asker) — does that become a stated rule in the ideas doc?
- **Which authoring sharp edges block an OSS core?** Proposed bar: anything whose failure mode is silent (dropped resource beyond nesting depth, dropped non-string edge) or whose error doesn't name the cause (serviceName recursion) must be fixed before external authors; the rest can be documented gotchas.
