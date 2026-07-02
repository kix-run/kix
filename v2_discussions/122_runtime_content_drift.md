# 122: Runtime content drift — the observed-hash design

**Status:** Draft
**Related:** `archive/51_merkle_health_check.md` (predecessor: integrity walk + "stamp a content-hash" future note), `106_ops_lifecycle_verbs_and_capacity_check.md` §1.4 (`kix drift` verb), `111_operator_experience.md` (node-state taxonomy), `81_deploy_as_lifecycle_engine.md` (`Verdict::DriftDetected`), `62_operator_production_implementation_plan.md`

## Problem

kix has two notions of resource identity, and only one of them works at runtime:

1. **Identity-hash** (works). The Nix store path of the manifest (`builtins.toFile`
   over manifest JSON + dependency string-context, `kix/lib/k8s.nix:318`). Merkle
   by construction. Stamped as `kix.dev/identity-hash` by `stamp.rs` at deploy.
   Every live code path — planner (`apply.rs:255` `detect_changes_live`), operator
   reconcile (`controller.rs:314`), `kix health`, GC — compares this **annotation
   string**. This detects *DAG drift*: missing resources, orphans, stale versions.

2. **Content-hash** (does not work). `cli/kix/src/cluster/normalize.rs` contains a
   complete Blake3 content-hash pipeline (`normalize_for_content_hash`,
   `detect_drift`, `project_onto_shape`) — **with zero production callers**. The
   ROADMAP marks content-hash drift detection `[x]`; in reality `kix health` is a
   dependency-presence walk and never compares field content.

Consequence: `kubectl edit` a field, leave the annotation intact, and every kix
surface reports the cluster as in sync. The live ludo cluster demonstrates this
today: someone bumped `immich-server`'s image via kubectl (manager
`kubectl-client-side-apply`, 2026-06-27) and restarted it via `kubectl rollout`;
the live PackageInstance still says `v2.7.2` while the live pod runs `v2.7.5`.
kix sees nothing.

### Why the obvious fixes don't work

**Recomputing the identity-hash from the live object is impossible.** It is a
store-path hash over the pre-apply manifest bytes *plus Nix string-context of
dependency store paths*. The live object has been mutated by the server and by
kix's own post-hash stamps, and the dep context isn't recoverable from the
32-char digests in `kix.dev/depends-on`.

**Comparing a build-time ("declared") content-hash against the live object is
unreliable.** Empirically verified against the live ludo cluster (built
`cluster-ludo` and replicated `normalize.rs` semantics — normalize both sides,
project live onto intended shape, compare): 179/193 resources hash-equal, and
the 14 mismatches are *systematic representation gaps*, not strippable noise:

| Class | Example (real, from ludo) | Why unfixable client-side |
|---|---|---|
| Zero-value omission | `readOnly: false` (cilium), `initialDelaySeconds: 0` (cilium-operator), `env[].value: ""` (reflector) — present in intended, absent in live | Go `omitempty` drops zero values on server serialization. Knowing that `false` was omitted vs never set requires the OpenAPI schema per field. |
| Write-only fields | Secret `stringData` → server stores `data` (5 secrets) | Representation transform, schema-dependent. |
| Quantity/format canonicalization | `1000m` → `1`, port names vs numbers | Server-side canonicalization rules. |
| Lifecycle | completed Jobs GC'd | Not drift, needs kind-aware policy. |

Nulls are trivially strippable (and already are). The zero-value class is
different: whether the server *keeps* an explicit `false`/`0`/`""` depends on
the Go type of the field — value-typed with `omitempty` (VolumeMount
`readOnly`, EnvVar `value`, Probe `initialDelaySeconds`) is dropped on
serialization; pointer-typed (`spec.replicas`, `suspend`, `runAsUser`)
preserves an explicit zero because K8s made absent-vs-zero semantically
distinct there (`replicas: 0` is scale-to-zero, absent is default-1;
`runAsUser: 0` is root). Symmetrically stripping *all* zero values from both
sides would mostly work but erases exactly that distinction — trading false
positives for false negatives on the security-relevant fields — and does
nothing for `stringData` or quantity canonicalization. Telling the two classes
apart per field *is* the OpenAPI schema. Exact-hash equality between a
pre-server and post-server representation is the wrong contract.

## The insight: hash the server's representation on both sides

The apiserver already gives us two primitives that make runtime content drift
tractable, both currently unused:

1. **The SSA response echo.** kix applies via server-side apply with field
   manager `kix` (`apply.rs:317`). The apply response *is* the committed,
   canonicalized, defaulted object — the exact representation any future GET
   will return. A hash computed from it is directly comparable to a hash of the
   live object later, with zero normalization heroics.

2. **`managedFields`.** The server maintains, per field manager, exactly which
   fields kix owns (`fieldsV1`). This is a server-maintained *projection mask*:
   "the subset of the live object that kix put there." Crucially, SSA ownership
   semantics make it a drift detector by itself: when another actor changes a
   kix-owned field, **ownership transfers to them and the field leaves kix's
   set**. On live ludo, kix's fieldsV1 on `immich-server` no longer contains
   `f:image` — the manual edit is recorded field-precisely, with the culprit
   manager and a timestamp, by the apiserver, for free.

## Design

### The three-layer identity model

| Layer | Annotation | Computed | Answers |
|---|---|---|---|
| DAG identity | `kix.dev/identity-hash` (existing, unchanged) | build time (store path) | "Is the right *artifact version* deployed, with the right dependencies?" |
| Applied content | `kix.dev/applied-hash` (new) | **from the SSA response** at apply time | "Has the body changed since kix committed it?" |
| Field ownership | `metadata.managedFields` (server-maintained, not ours) | continuously by apiserver | "Which fields does kix still own; who took what, when?" |

`kix.dev/content-hash` is already taken by the SOPS secret ciphertext hash
(`scope.nix:1485`, `secrets.rs:19`) — hence `applied-hash`.

### Stamping (deploy time)

After the SSA in `apply.rs:331` succeeds:

1. Take the apply **response object** (currently discarded by
   `apply_patch_with_retry`).
2. Extract kix's `fieldsV1` (manager `kix`, operation `Apply`) from the response.
3. Project the response onto that fieldset (a proper `fieldsV1` interpreter:
   `f:` members, `k:{...}` associative-list keys, `v:` set values — strictly
   better than `normalize.rs`'s index-based array projection, which breaks on
   keyed-list reordering).
4. Normalize: strip `kix.dev/*` annotations (self-reference), volatile metadata,
   status. Keep the existing helpers; drop the zero-value guesswork — it is no
   longer needed because both sides of every future comparison are
   server representations.
5. `applied-hash = blake3(canonical-json(projection))`.
6. Write it in the **existing second merge patch** (`apply.rs:346`,
   `update_activations_annotation`) — no extra round trip. The annotation is
   excluded from its own hash by step 4.

Also at deploy time, as a byproduct: diff *intended* vs *response projection*
and surface rewrites as a structured diagnostic (doc 80) — "admission webhook /
server rewrote `spec.x` from A to B". This is mutation *visibility* at the only
moment it can be attributed, not drift.

### Checking (runtime, no nix build, no store)

For any kix-managed live object:

1. GET (or receive via watch) with managedFields.
2. Extract kix's current `fieldsV1`, project, normalize, hash — same recipe.
3. Compare against `kix.dev/applied-hash`.

Match ⇒ every field kix applied is byte-identical to what the server committed
at apply time. Mismatch ⇒ classify by comparing fieldsets:

- **Content drift** — same fieldset, different values: someone force-SSA'd as a
  different value under kix's ownership, or an edge case; rare under SSA.
- **Ownership drift** — kix's fieldset shrank: the dominant real-world case
  (`kubectl edit`/`apply` transfers ownership). Attribution is a lookup: find
  the manager whose fieldsV1 now contains the lost fields, report
  `spec.template.spec.containers[image] taken by kubectl-client-side-apply at
  2026-06-27T09:45:36Z`. This turns drift reports from "hash mismatch" into an
  audit trail.

This is the "deep drift without nix build" future note of doc 51, made sound.

### Consumers (wiring plan)

1. **Fix the phantom manager first.** The activations merge patch runs with
   `PatchParams::default()` (`apply.rs:540`) — it shows up as manager `unknown`
   on every kix resource on live ludo. Set a field manager (`kix`). Trivial,
   independent, do it regardless.
2. **`kix drift` / `kix health --deep`** (doc 106 §1.4): LIST kix-managed
   resources, run the check, report per-resource verdicts with attribution.
   Cluster-only, seconds, no build. The dormant `normalize.rs::detect_drift`
   (build-vs-live, projection by intended shape) is superseded and deleted;
   `content_hash`/strip helpers are reused.
3. **Planner integration**: `detect_changes_live` today Skips when
   identity-hashes match, silently preserving drift unless `--reconcile`
   re-applies *everything*. Add the applied-hash check on identity-matching
   nodes: mismatch ⇒ new node state `drifted` (extends doc 111's taxonomy) ⇒
   re-apply just those nodes. `--reconcile` becomes "heal drifted", not
   "re-apply world".
4. **Operator**: watch events on kix-managed resources → recompute → emit the
   never-constructed `Verdict::DriftDetected` (`stream.rs:97`; every consumer
   already has a match arm) → status condition on the Activation CR, optional
   auto-heal (re-apply from closure — the operator has the desired manifest).
   Periodic full sweep as backstop for missed watch events.

### Edge cases and policy

- **Legitimate co-owners** (HPA on `replicas`, cert-manager on Secret data,
  controllers writing their own CRs' spec): ownership transfer is *expected*
  there. Handled by the derived/declared ignore surface — see "Deriving the
  ignore surface" below. Note: the moment a field is taken by another manager
  it also leaves kix's fieldset for the *next* stamp, so drift noise
  self-heals on redeploy; the policy exists to keep the window between
  take-over and next deploy quiet.
- **Skip path**: nodes the planner Skips are not re-applied, so their stamp is
  not refreshed. That is correct — content unchanged ⇒ hash still valid. The
  drifted-state check (consumer 3) runs *before* Skip is finalized.
- **Secrets**: the projection includes `data`. An unsalted hash of low-entropy
  secret material is dictionary-attackable by anyone who can read annotations —
  but on Secrets, annotation read ⇒ object read in practice (no metadata-only
  RBAC verb). Cheap hardening anyway: salt the hash with `metadata.uid`.
- **Completed Jobs / TTL'd resources**: lifecycle-aware exemption (already a
  concept via PI `spec.lifecycle`); "missing" is not drift for run-to-completion
  kinds.
- **Multi-activation shared resources** (CRDs, Namespaces): last writer stamps;
  identical content by construction (same store path), so the hash is stable
  across activations.
- **Trust framing**: the applied-hash attests "unchanged since kix applied",
  not "matches the artifact". The chain is: identity-hash ties the live object
  to the store artifact; the deploy-time intended-vs-response diff ties the
  artifact to the committed state (rewrites surfaced, not hidden); applied-hash
  ties the committed state to now. Each link is checkable at the layer where
  the information exists.

### Deriving the ignore surface (drift policy)

Split out to `123_compiled_delegation.md`: the **compiled-delegation
principle** (delegation derived only from controllers inside the activation —
never inferred from live state), the two derivation patterns (authoring-time
`autoscale` intent that dissolves the problem by never owning the field;
assembly-time delegation scan carried on the target's PackageInstance as
`spec.driftIgnore`), the field-side and controller-side runtime assertions,
and the staging argument (the seal is the stage boundary). The check in this
doc consumes that policy as a set of JSON pointers excluded from the
projection on both stamp and check side, resolved at runtime via the
`kix.dev/package` annotations → PI GET.

## Prior art: Argo CD and Flux

Both incumbents hit the same representation problem and landed on the same
underlying insight — get the *server's* rendering of desired state — but with
a different availability assumption:

- **Argo CD** diffs continuously; its classic strategy is client-side semantic
  normalization plus user-authored `ignoreDifferences` (jsonPointers,
  jqPathExpressions, `managedFieldsManagers` — ignore all fields owned by a
  named manager). Its newer **Server-Side Diff** sends the desired manifest as
  a dry-run SSA and compares the server's predicted object against live,
  eliminating most defaulting/admission false positives.
- **Flux** (kustomize- and helm-controller) detects drift on every reconcile
  by **dry-run server-side applying** the stored desired manifests and
  checking whether the result differs from live; `.spec.driftDetection.ignore`
  takes RFC-6901 jsonPointers with optional target selectors.

Both can do this because desired state is runtime-adjacent by construction
(Argo's repo-server, Flux's in-cluster source artifact). kix's runtime has no
desired state without a nix build — that gap is exactly what the stamped
applied-hash closes.

**Why don't they stamp — and why don't we dry-run?** Their model is
level-triggered: git is truth, the cluster is a disposable cache, and every
reconcile recomputes the comparison from source. A cluster-stored hash is
state they neither need nor trust; and hash equality only answers
"changed?" — their UI must render *what* changed, which needs the desired
manifest they already hold. kix inverts the economics: desired state costs a
nix build plus a repo checkout, so we cache the commitment on the object at
the moment it is made. Consequences: `kix drift` runs from any
kubeconfig-only context — no repo, no nix, no resident controller — which
neither tool can do; the price is that a mismatch names the drifted fields
and the culprit manager (managedFields) but not old→new values. The full
value diff remains a build — or the dry-run repair path once the operator
carries the closure (docs 62/89). The derived-ignore layer above is also
unique to kix: their ignore lists are hand-authored because they never see
the whole graph at build time.

## Known downsides of the applied-hash

- **Attests "unchanged since kix applied", not "matches the artifact".** The
  trust anchor is the cluster. Deliberate tampering (edit the field *and*
  recompute the annotation) is not defended — that is activation signing
  territory (`interesting_thoughts/54`). Accidental/operational drift, the
  actual problem, is fully covered.
- **Stamp is a second write.** A crash between the SSA and the merge patch
  leaves a stale/missing hash → false drift until the next apply. Acceptable:
  re-stamping is idempotent and any reconcile heals it.
- **Leans on managedFields integrity.** Backup/restore tools and etcd surgery
  can drop or garble managedFields → mass false positives until redeploy.
- **Representation shifts on upgrades.** An apiserver or CRD storage-version
  upgrade may change canonical serialization → cluster-wide false drift after
  upgrade. Detectable (version change) and healable (reconcile re-stamps);
  the drift report should say "cluster upgraded, run kix deploy --reconcile"
  rather than screaming.
- **Atomic-field granularity.** `x-kubernetes-map-type: atomic` subtrees own
  as one leaf; drift is still detected but localization degrades.
- **Bespoke.** Nobody ships exactly this (because everyone else holds desired
  state); the fieldsV1 interpreter is ours to maintain. It is, however, a
  well-specified, versioned format.

## With the closure at hand: detection vs diagnosis

The operator/CLI will carry the built activation closure (docs 62/89), which
removes the rebuild-and-checkout argument entirely. Content hashing still
earns its place, because the closure changes what *diagnosis and repair*
cost, not what *detection* costs — and detection is the part that must scale.
Per-resource, per-cycle apiserver impact:

| Mechanism | apiserver cost | yields |
|---|---|---|
| watch event → local hash vs stamp | ~0 — the operator receives these events anyway | kix-owned field changed: yes/no + culprit |
| periodic LIST → local hash | one paginated LIST per sweep | same, catches missed events |
| dry-run SSA vs live (Flux-style) | a **write-path** round-trip per resource — full admission chain and mutating webhooks run, even though nothing persists | value-level old→new diff |
| blanket re-apply (`--reconcile`) | full write per resource, resourceVersion churn, webhook load | heals everything, observes nothing |

A massively-scaled operator cannot pay row 3 continuously — that is the load
profile to avoid. The applied-hash inverts the pyramid: **detection rides the
watch stream at near-zero marginal cost** (hash only on generation or
managedFields change), and the closure is consulted only *after* a resource
is flagged — one dry-run of one desired manifest to render the value diff,
one targeted re-apply to heal. Detection continuous and cheap; diagnosis
precise and on demand.

This also closes the zero-emission question for the closure era: the
omitempty problem only exists when comparing *across* representations. The
hash path never does (server vs server); the diagnosis path hands the
comparison to the server itself (dry-run). No client-side schema simulation
in either.

## Why not predict the server representation at compile time?

The schemas are public and available at build time — so why not normalize the
intended manifest into the *predicted* server representation and stamp a
build-time hash (nicely inside the Merkle, artifact-anchored)? Four reasons,
in increasing order of fatality:

1. **The decisive information is not in the schema.** Whether an explicit
   `false`/`0`/`""` survives round-trip depends on the Go field being
   pointer-typed vs value-typed-with-`omitempty` — a source-level decision.
   The published OpenAPI document marks both merely as *optional* and encodes
   no distinction. (The K8s API conventions say when authors *should* use
   pointers, but conventions are not a contract, and CRD authors follow their
   own habits.) You would end up hand-maintaining exactly the table the
   schema was supposed to provide.
2. **Native defaulting is imperative Go**, not schema data. OpenAPI v3
   publishes some defaults; coverage is partial. CRD structural-schema
   defaults are the exception, not the rule.
3. **Mutating admission webhooks** are cluster-runtime facts. Any webhook
   touching kix-owned fields (hardening injectors, sidecars, CA injection)
   falsifies a compile-time prediction. The apply echo includes them by
   definition.
4. **SOPS hydration is deploy-time.** The build artifact does not contain
   secret plaintext, so a build-time hash structurally cannot cover the
   hydrated Secret the server commits.

Each gap is individually patchable; the sum is an apiserver simulator,
version-coupled and forever chasing upstream — the road Argo walked with
client-side known-types normalizers before retreating to Server-Side Diff.
Note the echo approach is self-consistent even on the omitempty class: the
applied config may say `readOnly: false` (so the fieldset lists it), but both
the echo and every later GET serialize without it — stamp and check see the
same absence.

What compile-time stamping would buy — attestation anchored in the artifact
rather than the cluster — is already covered at the right layer:
identity-hash anchors the artifact, and the deploy-time intended-vs-echo diff
surfaces (and can record) what the server rewrote. If air-gapped attestation
ever demands a predicted hash, it is an *additive* annotation on top of this
design, not a replacement.

## Alternatives considered

- **Wire up `normalize.rs::detect_drift` as-is** — requires a nix build (defeats
  "runtime"), index-based array projection corrupts keyed lists, and the
  zero-value / stringData classes above are unfixable without OpenAPI schemas.
  Rejected; measured 14/193 systematic false positives on a healthy baseline.
- **Declared hash stamped at eval time** (`builtins.hashString` in `k8s.nix`) —
  the pre-/post-server representation gap, in full in "Why not predict the
  server representation at compile time?" above.
- **Store the full normalized manifest in an annotation** (CSA
  `last-applied-configuration` style) — enables field diffs without a build,
  but costs size (256KB cap), leaks Secret plaintext into an annotation, and
  managedFields attribution already provides the field-level story.
- **Server dry-run at check time / closure-carrying diff loop** — see "With
  the closure at hand": right tool for on-demand diagnosis and `kix diff`
  noise-reduction (`kix diff --server`), wrong load profile for continuous
  detection.

## Implementation phases

1. **P0** — ~~set field manager on the activations merge patch~~ **done**
   (`apply.rs` `update_activations_annotation` now passes `field_manager:
   "kix"`; previously recorded as manager `unknown` on every kix resource).
2. **P1** — `fieldsv1` projection module + `applied-hash` stamping in the apply
   path (compute from response, ride the existing merge patch). Unit tests
   against recorded fixtures from ludo; integration test in the kind cluster.
3. **P2** — `kix drift` (one-shot, doc 106 §1.4) + `kix health --deep`
   cluster-only mode. Delete `detect_drift`/`project_onto_shape`.
4. **P3** — planner `drifted` node state + targeted heal; retire blanket
   `--reconcile` semantics.
5. **P4** — operator watch-driven check emitting `Verdict::DriftDetected` +
   Activation status condition; periodic sweep.

## Open questions

- **Delegation table contents**: HPA and KEDA are clear; what else earns a
  built-in entry vs package-declared? (VPA in `Auto` mode mutates *pods*, not
  the workload spec, so it likely needs nothing.)
- **Downgrade window**: between a foreign take-over and the next kix deploy,
  should `kix deploy` refuse (non-force SSA will 409 on the taken field) or
  auto-force with a diagnostic? Today non-force surfaces the 409 — probably
  correct, but the drift report should predict it.
- **fieldsV1 for CRs with atomic maps**: `x-kubernetes-map-type: atomic` fields
  appear as a single leaf; projection granularity degrades to whole-subtree.
  Acceptable, but the check should report at the granularity it actually has.
- Does the operator auto-heal by default, or report-only until doc 111's
  `kix status` surfaces drift to a human? (Current operator reconcile
  re-applies on identity mismatch already; extending to content drift changes
  blast radius.)
