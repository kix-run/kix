# 120: Compiler-theory mapping — what kix already is, in the literature's terms, and what it hasn't covered yet

**Status:** Analysis / Brainstorm
**Related:** `29_compiler-design.md` (the anchor: Merkle DAG as IR, pass taxonomy, language choice — settled, not re-litigated here), `119_core_surface_audit.md` (grammar/vocabulary, ring model), `80_structured_diagnostics.md`, `97_service_contract_primitives.md`, `98_deploy_execution_topology.md`, `117_kube_prometheus_stack_wrapping_validation.md`

## Purpose

Doc 29 argues *why* the Nix store is the right IR. This doc takes the next step a compiler-engineering postdoc would: map kix's structures onto the named concepts of the field (so we can borrow their literature, vocabulary, and known failure modes), and then walk the standard compiler surface area to find what kix hasn't (sufficiently) explored. The payoff of naming things correctly is that each named correspondence comes with decades of prior art on what goes wrong.

## 1. The pipeline, mapped

| Classical stage | kix realization | Status |
|---|---|---|
| Lexing/parsing | inherited from Nix (embedded DSL — no syntax of our own) | free, with consequences (§3.5) |
| Declarations pass | phase 1: `normalizePackage`, `functionArgs` introspection, `peekPackageMeta` | done |
| Name resolution / linking | DI resolution ladder (`resolve.nix`); `buildCluster` = whole-program link; `mergeFragments` = separate compilation units | done, but untyped (§3.1) |
| Type checking | `lib.mkOption` types on config; **nothing on the `out` interface** | half-built |
| Semantic analysis | validator catalog in `scope.nix`; structural warnings post-fixpoint | strong |
| IR | content-addressed store DAG (doc 29 §8) | the crown jewel |
| Legalization (target-gating) | capability gates (`checkDaemonSet`, `checkLoadBalancer`, `checkPrivileged`) against the flavor's instruction set | present, coarse (§3.8) |
| IR→IR passes | netpol derivation, label stamping, hardening pass (115), `partsOverlays` | present, some opaque (§3.5) |
| Lint / static analysis | scorecard engine + rules | built, opt-in |
| Canonicalization | helm strip (defaults, bookkeeping annotations), `stripKixMeta` | present, diff-driven |
| Emission | `mkManifests`, Activation closure | done |
| Loader / runtime | CLI deploy engine: waves, readiness gates, import polling | done; evolving to dataflow (98) |
| Debugger / debug info | `kix.dev/*` annotations, SARIF export | thin (§3.2) |

## 2. Correspondences kix already implements — name them and use the literature

- **Hash-consing / global value numbering.** Content addressing means two identical resources are literally the same store path, and `identityHash` is a semantic fingerprint. This is GVN at the artifact level; doc 29 §8 catalogs the consequences. Known failure mode from the literature: hash-equality is exact-equality — semantically equivalent but differently-serialized values don't dedupe (why canonicalization, below, matters so much).
- **Weak vs strong symbols.** Flavor platform imports are weak symbols (`platform-dns` from the kind flavor); managed instances are strong symbols that override them ("managed shadows imports" in `resolve.nix`). Missing required dep = undefined symbol; two candidates = duplicate symbol, and kix correctly makes it a hard error rather than picking (linkers that pick silently are a notorious bug source).
- **Legalization.** The capability gates are exactly instruction legalization: refuse to emit a DaemonSet for a target whose ISA lacks one. The flavor is the target triple (per 119: capabilities = instruction set, platform imports = ABI).
- **Canonicalization before comparison.** Helm strip + default-`strategy` removal is the canonical-form pass every optimizing compiler runs before CSE; here it serves the diff (compiled vs live). The K8s API server's defaulting is the "microarchitecture" that mutates emitted code — normalization must model it or diffs lie. `scripts/nw1-diff-ignores.txt` is this knowledge accumulating as data; it wants to become a real pass.
- **Translation validation.** `kix-diff` against a live-cluster dump is translation validation (prove the compiled artifact and reality agree) rather than verified compilation. Doc 117's helm-wrap-vs-native comparison is **differential testing** between two compilation strategies of the same program — a named, powerful technique worth institutionalizing (§3.7).
- **List scheduling → dataflow execution.** Waves are list scheduling on the DAG with barriers; doc 98's move to DAG-streaming is precisely in-order → out-of-order execution. The literature's warning transfers: out-of-order needs precise hazard tracking — readiness verdicts (81) are the scoreboard.
- **Two-phase compilation.** Phase 1 (introspect signatures, no bodies) / phase 2 (fixpoint build) is the declarations-then-definitions split every incremental compiler makes. kix stumbled into the right architecture; §3.3 is about cashing it in.
- **Unsafe-is-visible.** `rawSelector` tripping `selectorCoherence`, `extra` being blocked from managed fields — this is Rust's unsafe-block discipline: escapes allowed, marked, and greppable. Doc 29 §7.3's "track uncompiled fields" open question is the full version of this and remains open.

## 3. Surfaces a compiler normally covers that kix hasn't (sufficiently) explored

Ordered roughly by how directly each serves the pitch (verifiable artifact, told-at-eval-time).

### 3.1 Link-time type checking — the biggest gap

DI resolves *names* but never checks *signatures*. Resolving `postgres` succeeds if any instance carries the alias; whether its `out` actually has `fqdn`, `credentials`, `port` is discovered at use-site as a raw Nix attribute-missing error deep in eval. That is a linker resolving `extern` symbols without comparing types — the C linker's most infamous deficiency (works until it doesn't, then the error is unintelligible).

- What exists: `compatibleWith` version bounds (checks the version *number*, not the shape); doc 97's `provideService` contract; doc 29 Tier 2's "env-var wiring checked against the `out` contract."
- Direction: an interface declaration per DI role (`postgres` implies `out ⊇ { fqdn, port, credentials }`), checked at resolution time with a source-attributed diagnostic naming both parties. Capability contracts (doc 100 §capability) are the typeclass version. This single feature converts the worst author-facing error class (opaque eval trace) into the best (link error naming both sides), and it's what makes `mkImport` stand-ins safe — today an import with a misspelled `out` field is a delayed bomb.

### 3.2 Debug info and field-level provenance

Doc 29 §8.2 gives resource-level provenance (walk the DAG). Compilers additionally carry *source maps*: which line produced this instruction. The kix equivalent — "why is this field this value?" — has four possible answers (package default, instance config, dep injection, overlay/flavor) and no tool answers it. The NixOS module system already tracks definitions with locations (`options.<x>.definitionsWithLocations`) — the machinery half-exists for the config layer; nothing covers `partsOverlays`, `patchResources`, or merged manifests.

- Direction: a `kix explain <resource> [field-path]` query that prints the contribution chain. Doc 111's operator experience (cause pointers, blast radius) is the consumer. This is also the honest answer to "the recurring cost is indirection" in `guide/00-ideas.md` — you don't remove indirection, you make it inspectable, exactly as debuggers did for optimized code.

### 3.3 Incremental compilation — and correcting doc 29's claim

Doc 29 §8.2 claims "change one package in a 200-package cluster → only that package and its dependents are re-evaluated." That's true of *derivation realization*, not of *evaluation*: the Nix evaluator re-runs the whole cluster fixpoint on every invocation, and `importChart`'s IFD inserts build-time work into the eval path. Today's mitigation is laziness (evaluate one attr), not incrementality (reuse last run's work).

- What the field does: query-based compilation (Salsa/rustc's red-green algorithm) — memoize queries, invalidate by input fingerprint. The two-phase split (§2) already isolates the cheap query layer (phase-1 metadata) from the expensive one (phase-2 fixpoint).
- Direction: don't build incremental Nix; move the queryable layers out. The Rust-oracle idea (`interesting_thoughts/36`) and the CLI already owning post-eval analysis point the way: phase-1 metadata and the resolution index are cacheable per package content-hash; helm IFD results are cacheable by (chart hash, values hash) — **shipped**: `helmTemplateDerivation` and `importChartCrds` now discard string context from the values file, so the render derivation's cache key is exactly chart + values text + flags, and dep changes no longer force re-renders.

### 3.4 Error recovery and batch diagnostics

Nix throws on first error; production compilers recover and report dozens per run, because authors fix in batches. A migration (116) hits this hard: fix one eval error, rebuild 2 minutes, hit the next.

- What exists: doc 80 (deferred + fatal diagnostics, structured transport) is exactly this and is Active — this section just adds the compiler-lens requirements: (a) *recovery points* at package boundaries (one package failing to build shouldn't kill diagnostics for its siblings — evaluate instances in `tryEval` islands, aggregate), and (b) *error codes* (rustc's `E0308` model) so diagnostics become linkable/documentable. The `--explain` pattern pairs naturally with the guide.

### 3.5 The embedding boundary — shallow vs deep, and the analyzability line

kix is a *deep* embedding at the resource level (resources are reified data the compiler can inspect) and a *shallow* embedding above it (build functions, `patchResources`, `partsOverlays` are opaque host-language functions). Every analysis blindspot kix has sits exactly on that line: netpol can't see through helm charts or hand-built strings; the DAG can't see an edge a function computed without string context; `capabilityOwnership` can't attribute what an overlay minted.

- The named principle: **you can only verify what you reify.** Doc 92 (netpol intents as data replacing hand-rolled CRs) and doc 110 (alerts as resources) are already instances of it.
- Direction: adopt it as a stated design law — when a surface needs analysis, its input must be data, not a function; functions are for the escape hatch ring only. This gives a principled answer to future "should this be a function or a schema" debates, and it's the compiler-theory grounding for 119's rule 4 (sub-DSLs must compile to inspectable shapes).

### 3.6 ABI stability and interface versioning

`out` is the ABI, and it has no versioning story. `compatibleWith` gates on the *package* version; nothing detects that a package renamed `out.fqdn` → breaking every consumer at eval with attribute-missing errors (see 3.1). Doc 29 §8.3's hash-based impact contract detects *that* something changed, not *whether the change was breaking*.

- What the field does: symbol versioning, semver-checked interfaces, `cargo semver-checks`-style diffing of the public surface between versions.
- Direction: once 3.1's interface declarations exist, an `out`-surface diff between package versions is mechanical, and "this bump breaks consumers X, Y" becomes a compile-time report. Cheap to build after 3.1; pointless before it.

### 3.7 Testing practice from compiler engineering

Compilers are the most-tested software category, and their techniques transfer almost verbatim because kix eval is pure (same input → same artifact — fuzzing and snapshots are cheap):

- **Golden/snapshot tests** — per-package expected-manifest snapshots; a diff is a review artifact, not a failure. (ludo-kind smoke build is a coarse version.)
- **Differential testing** — doc 117 (helm-wrap vs native rebuild of the same stack) is this; make it a harness, not a one-off. Also: kix-compiled vs `helm template` for any wrapped chart, continuously.
- **Fuzzing the option space** — random walks over declared option types per package; every crash is either a missing validator or a missing type. `anything`-typed options are unfuzzable, which is itself a finding (they're also unvalidatable — same root cause).
- **Crash triage discipline** — any eval error that is not a kix-authored diagnostic is a bug in kix, full stop (the rustc "ICE" convention). This single policy would drive the sharp-edge list in 119 to zero over time.

### 3.8 Legalization completeness — the target model is coarse

Capabilities are today a handful of booleans. Real target models are versioned feature matrices. Concretely missing (both already flagged in doc 29 Tier 1, still open): `apiVersion` deprecation/removal checking against `k8sVersion` (the K8s deprecation schedule is static data — this is a pure legalization pass), and CR validation against CRD schemas (`mkCRD` carries the schema; `mkCR` doesn't check it — the permissive-default schema in `crd.nix` makes this worse by making no-validation the default).

### 3.9 Deliberate non-goals worth stating (so nobody "fixes" them)

- **No optimization passes.** The artifact is meant to be reviewed; kix permanently emits the equivalent of `-O0` with full debug info. Dedup happens at the store layer for free; nothing should rewrite manifests for size/elegance.
- **No runtime abstraction.** The loader (CLI) executes the artifact; it must not grow reconciliation cleverness that makes the artifact less predictive (doc 81 keeps lifecycle knowledge *kind-aware but plan-driven*). The pitch is "know what will happen"; a smart runtime erodes it.
- **Hygiene, minimally.** Dep config injection is a macro system writing into another package's namespace; `mkLocked` is the hygiene guard. Full hygiene machinery isn't warranted until real collisions occur (119's demand test) — but injections should at least be visible in provenance (§3.2).

## 4. Priority read

1. **3.1 link-time contracts** — converts the worst error class; unblocks 3.6; doc 97 is the vehicle.
2. **3.4 batch diagnostics** — doc 80 is already Active; add recovery points + error codes to its scope.
3. **3.2 field provenance** — the operator-experience multiplier (111); module system already half-tracks it.
4. **3.8 legalization data passes** — apiVersion schedule + CR schema checks; high value, mostly data, low design risk.
5. **3.7 testing harnesses** — differential + snapshot first; fuzzing after the `anything` options shrink.
6. **3.3 incrementality** — helm-IFD caching now; query-based architecture only when eval latency hurts real users.

## Open questions

- Interface declarations for DI roles (3.1): where do they live — on the *role name* (a cluster-level registry of what `postgres` means), on the consumer (structural requirement), or on the provider (`meta.provides` with a schema)? Provider-side matches `meta.provides`; role-side matches the DNS analogy; consumer-side matches structural typing. Pick one before doc 97 lands.
- Does "you can only verify what you reify" (3.5) get promoted into `guide/00-ideas.md` as idea 12, alongside the flavor-as-target statement from 119?
- Error codes (3.4): namespace them now (`KIX0xxx`) even before the catalog exists, so early diagnostics don't need renaming?
- Is the crash-triage policy (any non-kix-authored eval error = kix bug) acceptable as a stated quality bar for the OSS core?
