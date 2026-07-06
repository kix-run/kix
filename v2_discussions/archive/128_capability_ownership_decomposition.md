# 128: Capability-ownership decomposition — unsafe escapes and annotation domains

**Status:** Implemented (2026-07-06). Verified: 32-test kix/lib matrix, clean
`cluster-ludo` + `cluster-ludo-kind` builds; manifest diff vs main is exactly
the intentional removal of `kix.dev/capability: reflection` on the four
reflector-bundle resources (+ the resulting depends-on hash cascade) — the PVC
stamp revert restored full identity. In-practice notes: helm-imported chart
resources route through the wrapper's `mkResource`, so ONE enforcement point
covers native and chart PVCs; grafana/harbor/immich-machine-learning hold
audited `raw-pvc` grants pending refactor; prometheus-operator declares
`operator.prometheus.io`; ludo declares `prometheus.io` known (by-convention
scrape contract). Still open: vCT class-edge check → kixpkgs#30.
**Related:** `127_compiler_target_model.md` (roles-as-linker-symbols parent), `interesting_thoughts/83_package_owned_scorecard_rules.md` (absorbed by mechanism 2 — archive on ship), `archive/60_scorecard_rules_design.md` (scorecard framework reference), `63a_storage_as_cluster_concern.md` (rationale for why raw PVCs are wrong)

## Context

The scorecard's `architecture.capabilityOwnership` rule (`kix/lib/rules/architecture.nix`)
is one generic warning driven by a fingerprint registry: a resource matching a
fingerprint (kind == `PersistentVolumeClaim`, or the string
`reflector.v1.k8s.emberstack.com` appearing in annotations/labels/container
args/RBAC) must carry a `kix.dev/capability: <name>` provenance annotation
stamped by the capability owner's canonical code path, else the rule fires.

The rule unifies two genuinely different problems under one
capability-flavored heuristic:

1. **Raw PVCs in package builds** — a structural authoring violation.
   Storage is the cluster operator's concern (doc 63a); a package hand-rolling
   a PVC hard-codes size/storageClass/lifecycle decisions that aren't its to
   make. This is the same *class* of invariant as the existing eval-time
   validators (`checkLoadBalancer`, `checkPrivileged`, `checkDaemonSet` in
   `kix/lib/scope/validators.nix`) — and those throw; they don't emit a
   scorecard warning someone can scroll past.

2. **Hand-written reflector wiring** — writing configuration for an operator
   you don't link against. The actual invariant is a missing dependency edge,
   not a resource-content pattern. String-scanning container args to catch it
   is fingerprint cleverness that ages badly.

The unification also forces the worst parts of both onto each: the PVC case
gets warning severity when it deserves an error, and the reflector case gets
runtime-visible `kix.dev/capability` stamps as provenance when a compile-time
dep edge states the invariant directly.

**Decision (previous session):** decompose into two declared invariants
enforced at eval, delete the fingerprint rule, revert the stamps.

## Design

### Mechanism 1: raw-PVC eval error with a rust-style `unsafe` escape

**Invariant:** no package build emits a raw `kind: PersistentVolumeClaim`
unless the package explicitly declares the unsafe grant in its meta.

**Enforcement point:** a new `checkRawPvc` in `mkValidators`
(`kix/lib/scope/validators.nix`), wired into the `mkResource` path in
`kix/lib/scope/builders.nix` next to the existing `checkLoadBalancer` seq
(builders.nix:29). It throws — same severity model as its siblings.

**Escape hatch:** `meta.unsafe = [ "raw-pvc" ]`, read via `peekPackageMeta`
(`kix/lib/meta.nix`) at the same phase-1 timing the roles map in
`eval/hooks.nix` already uses, so the validator knows the grant without a
fixpoint problem. Like `meta.roles`, the vocabulary is **closed**: a small
registry (name + description + rationale) with an `assertKnownUnsafe` guard,
so a typo'd grant errors instead of silently never matching. First and only
entry: `raw-pvc`, granted to `packages/persistent-volume-claim` — the one
canonical implementation.

**Auditability:** a new info-level scorecard rule lists every unsafe grant in
the cluster (package, grant, description) — the `#![allow]` audit. An unsafe
grant is never invisible in review; it just isn't a warning to dismiss.

**Helm imports:** `mkValidators` only runs on `scope.mk*` paths — imported
chart resources bypass it entirely. Charts with `persistence.enabled` emit raw
PVCs legitimately. Rather than a second escape vocabulary, the same one
applies: a package wrapping a chart that emits PVCs declares
`meta.unsafe = [ "raw-pvc" ]`, and the import path (where rendered resources
are already walked for wrapping) enforces the same check. One vocabulary, two
enforcement points, identical author-facing story: emitting a raw PVC from
any path requires the visible grant.

**Deliberate blind spot (v1):** `volumeClaimTemplates` inside StatefulSets
escape every PVC-kind check — and they're where most state actually lives
(stackgres, valkey). No variant of the old rule saw them either, so this is
not a regression; it is an open question below, not a v1 goal.

### Mechanism 2: declared annotation domains + DI-edge lint

**Invariant:** if any package in the cluster declares an annotation domain it
manages, then a package whose resources carry annotation *keys* under that
domain must have a DI dep on (an instance of) the declaring package.

**Declaration:** `meta.annotationDomains = [ "reflector.v1.k8s.emberstack.com" ]`
on the operator package (reflector). This is a new peekable meta field, *not*
a role: roles are DI aliases with binding modes and out-contracts
(`eval/roles.nix`); annotation domains are a different axis (an operator can
hold roles *and* declare domains). The vocabulary is open — domains are
foreign identifiers owned by upstream operators, so a closed registry would
gate on kix releases for no safety gain; the declarer itself is the registry.

**Detection:** prefix match on annotation keys only
(`<domain>/<name>` or exact `<domain>`). No label matching, no container-arg
scanning, no RBAC scanning — the entire `containsString` walker in
`rules/architecture.nix` dies. **Accepted loss:** a hand-rolled Job running
`kubectl annotate` at runtime writes reflector annotations invisibly to any
eval-time annotation inspection. The old arg-scan caught that; we let it go.
That pattern's real smell is "package runs kubectl against foreign resources,"
which deserves its own future check, not a domain grep.

**Semantics — one rule, not cases:** every domain-shaped annotation prefix
(contains a dot; `checksum/config`-style keys skip) needs a **declarer**, and
when the declarer is a package, additionally a dep edge. Declarers, in order:

- **Reserved builtin set** (closed, tiny): `kubernetes.io`/`k8s.io` suffixes
  (upstream reserves these for core components), `kix.dev`, `helm.sh`/
  `meta.helm.sh` (imported resources carry them). Pass.
- **Package in the cluster declaring the domain** → dep edge required.
  With it → pass (`reflector.out.reflectSecret` consumers pass by
  construction — the builder takes the dep arg; the edge also carries
  ordering and presence, everything the stamp faked). Without it →
  **warning** ("you are writing config for an operator you don't link
  against; declare a `reflector` dep"). Warning, not error: annotating a
  source Secret is a legitimate one-liner, and migration/adoption states make
  hand-annotation transiently legitimate.
- **Cluster-declared known domain** (`knownAnnotationDomains` in scorecard
  config): domains consumed by something outside kix — a cloud control plane
  (`eks.amazonaws.com`), org-convention metadata (`mycompany.com/owner`).
  Pass. v1 is one flat list; it graduates to target presets when doc 127's
  environment facts land (same trajectory as roles' environment bindings).
- **No declarer anywhere** → **warning** ("no operator in this cluster
  consumes `<domain>` — you likely forgot to link an operator, or declare it
  in `knownAnnotationDomains`"). This closes the hole where a hand-annotated
  Secret sits dead until runtime debugging: if the dep is never declared, DI
  never gets the chance to fail loudly, so eval must.

Two declared packages claiming the same domain is a duplicate-symbol eval
error, consistent with role binding-mode conflicts.

This **subsumes the dead-annotation registry idea**: instead of curating a
registry of good domains, the reserved set is closed and everything else is
declared by whoever consumes it. The registry never needs to exist.

**Dep-edge grain (grounded):** direct dep suffices. No core builder emits
foreign-domain keys — `mkSecretRef { reflect = true }` only sets internal
`_kix.reflected` metadata (`scope/builders.nix:635`); actual reflector
annotations come from `reflectSecret` (caller holds the dep) or hand-writing
(the lint's target).

**Wiring:** the lint needs two things the package-rule ctx
(`scorecard.nix#evaluatePackageRules`: `resources/parts/config/meta/instanceName/namespaceName`)
doesn't have today: the cluster-wide domain→declarer index (built from peeked
meta, same shape as the hooks.nix roles map) and this instance's resolved dep
packages. Both are available in `eval/cluster.nix` at the point package rules
are invoked; extend the ctx with `annotationDomainIndex` and
`resolvedDepPackages` (names only — no fixpoint hazard, deps are resolved
before rules run). This stays a scorecard rule (configurable severity,
structured reporting per doc 80) rather than a hard validator, matching the
warning semantics above.

### What gets deleted / reverted

Exit state: the fingerprint machinery and all provenance stamping are gone,
and ludo-kind manifests are byte-identical with main.

1. Delete `capabilityOwnership` + `fingerprints` + `containsString` +
   `getCapAnnotation` from `kix/lib/rules/architecture.nix`
   (`selectorCoherence` and `fqdnWithoutContext` stay).
2. Revert the `kix.dev/capability: storage` stamp in
   `packages/persistent-volume-claim/default.nix:80-84`.
3. Delete the `capAnnotations` stamping in reflector's `reflectSecret` builder
   (`packages/reflector/default.nix:38-40` and its uses) and the stale
   stamp-referencing comment in `packages/stackgres-cluster/default.nix:531`.
4. Fix stale docs: `kix/lib/architecture.md` line 86 (describes the
   annotation-only rule and the deleted `meta.provides`-era story) and the
   `eval/roles.nix` header comment referencing `meta.owns` — a field that
   does not exist in the code; it becomes `meta.unsafe`.
5. Archive `interesting_thoughts/83_package_owned_scorecard_rules.md` as
   absorbed: mechanism 2 *is* "move the fingerprint into the owning package,"
   resolved more sharply than 83 proposed (declaration + dep edge instead of
   package-shipped rule code).

**What we knowingly give up:** the `kix.dev/capability` annotation was
runtime-visible — `kubectl get` on a live resource showed which capability
authored it. The dep edge replaces the stamp at compile time; nothing
runtime-visible remains. Accepted: field-level provenance is doc 120's
"kix explain" territory and shouldn't ride on scorecard plumbing.

## Alternatives considered

- **Keep the fingerprint rule, add a `meta.owns` escape.** Rejected: still a
  warning for a structural violation, still string-scanning, and the escape
  hatch was never even implemented (the roles.nix comment references it; the
  rule is annotation-only). The decomposition replaces one heuristic with two
  declared invariants — more in the spirit of the compiler.
- **Annotation domains as entries in the roles registry.** Rejected: roles are
  a closed compiler vocabulary with binding modes and out-contracts; domains
  are open foreign identifiers with none of that machinery. Cramming them in
  would weaken the registry's "closed on purpose" guarantee.
- **Retain arg-string scanning for the kubectl-annotate Job case.** Rejected:
  it's the part of the old rule that ages worst (any operator whose domain
  appears in an image name or arg fires it), and the pattern it catches is
  better addressed by a dedicated "kubectl against foreign resources" smell.
- **Error severity for the annotation-domain lint.** Rejected for v1:
  migration/adoption states make hand-annotation transiently legitimate;
  warning + cheap fix (declare the dep) is the right pressure. Severity is
  operator-configurable via the scorecard anyway.
- **Separate escape vocabulary for helm persistence.** Rejected: one
  `meta.unsafe` grant covering both native and imported PVC emission keeps the
  author-facing rule simple ("raw PVC anywhere = declare the grant").

## Migration / verification

Order of operations (all on `v2/127-role-registry` or a follow-up branch):

1. Land mechanism 1 (validator + `meta.unsafe` + grant on
   persistent-volume-claim + import-path check + audit rule).
2. Land mechanism 2 (meta field + domain index + ctx extension + lint rule +
   reflector declares its domain).
3. Delete/revert (§ above) in the same change as 2, so the tree never has
   both the old rule and the new lints firing on the same resources.
4. Verify: kix/lib test matrix; `nix build ludo/#cluster-ludo` and
   `ludo/#cluster-ludo-kind`; manifest diff vs main must be empty
   (byte-identity restored once stamps are reverted). User commits (signing
   key needs passphrase).

## Open questions

- **volumeClaimTemplates — proposal sketched, severity undecided.**
  Tracked in [#30](https://github.com/adamcharnock/kixpkgs/issues/30). The vCT
  gap is not about the claim *object* (a per-replica template legitimately
  lives inline — no `meta.unsafe` grant applies) but about the **class
  decision**, which surfaces as a string in three places: vCT specs, operator
  CR fields (SGCluster `spec.pods.persistentVolume.storageClass`), and
  helm-emitted PVCs. Invariant: storage-class identity carries a DAG edge or
  an explicit opt-out — `fqdnWithoutContext` applied to storage. Three tiers:
  (1) `checkVolumeClaimTemplates` in `mkValidators`, StatefulSet-only:
  `storageClassName` absent → pass (cluster default = the `storageClasses`
  role provider); store-path context → pass; context-free literal → throw
  with `kix.untrackedRef` escape (the `checkNamespacedRefs` model — operator
  config passthrough is written `kix.untrackedRef config.persistence.storageClass`,
  so authorship is attributed in code; `""` = static-PV binding goes through
  untrackedRef too). (2) Ergonomic builder emitting template + matching
  volumeMount — belongs to doc 32, cross-reference only. (3) Manifest-level
  *warning* on context-free values of fields named
  `storageClassName`/`storageClass` anywhere — the only tier that sees helm
  imports and operator CRs; content-scan tension acknowledged, but keyed on
  core K8s vocabulary so it ages like `fqdnWithoutContext`, not like the
  reflector fingerprint. stackgres-cluster already passes (config > DI >
  throw, `default.nix:257-264`); valkey needs the optional `storageClasses`
  dep or an untrackedRef wrap (`default.nix:1296-1310`). Size stays
  unchecked — a size default is legitimate authorship. **Open:** tier 1
  error-vs-warning (error forces a mechanical untrackedRef edit on every
  config-passthrough vCT package; warning reintroduces scroll-past).
- **`meta.unsafe` granularity.** Is `raw-pvc` the right grain, or does the
  vocabulary want kind-shaped entries (`raw-storage`, future `raw-crd`,
  `raw-namespace` per doc 55)? Decide when the second entry shows up (doc
  119's demand test).
- **Labels under a declared domain.** v1 matches annotation keys only. Some
  operators select on domain-labels; extend only when a real declarer needs it.
