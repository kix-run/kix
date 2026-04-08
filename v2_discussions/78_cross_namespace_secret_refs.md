# 78: Cross-namespace `mkSecretRef` — Untying the Knot

**Status:** Brainstorm / Exploration
**Related:** `76_secrets_design.md` (§10.3 open question), `74_secrets.md` (§6 `mirrorOf`), `48_system_contracts.md` (cluster capabilities), `45_cluster_hardware_profile.md` (capability-driven compilation), `77_secret_access_control_modules.md`

---

## The Knot

Doc 76 specifies two primitives: `mkSecret` (kix owns the value, hydrated from SOPS at deploy) and `mkSecretRef` (the value lives outside kix — cert-manager TLS, Stackgres-rolled DB creds, Vault-synced, bootstrap pull secret).

K8s Secrets are namespace-scoped. When a consumer in namespace `B` needs a secret that lives in namespace `A`, kix knows the full wiring at **compile time**:

- which namespace the source Secret will exist in
- which keys it advertises
- which consumer in which other namespace needs which key
- whether the producing operator rotates it

We do **not** know the values.

For `mkSecret`, doc 74 §6 proposes `mirrorOf`: emit two Secret manifests, hydrate both from the same SOPS file at deploy time. This works because kix owns the source of truth.

For `mkSecretRef`, that escape hatch is closed:

1. **Build-time copy is impossible** — no values exist at build time.
2. **One-shot deploy-time copy** works exactly once. The moment Stackgres rotates the postgres user secret, the mirror is wrong, and there is no path back to consistency from inside kix.
3. **Continuous reconciliation by the kix operator** restores correctness but makes kix the *second writer* for a value it doesn't own. Race conditions, RBAC sprawl, unclear ownership on rotation.

The user's concrete pain: *"Stackgres rolls the secret → unrecoverable drift."* The knot is that kix has full structural knowledge but no claim on the value.

---

## Reframing

The instinct "copy the secret" is the wrong default. It treats the cross-namespace boundary as a packaging problem (move bytes around) when it is actually an **ownership problem** (who is allowed to update this value, and how do downstream consumers learn about updates).

Three reframings unlock the design space:

1. **kix is not the right entity to propagate operator-managed values.** Only the producing operator knows when a rotation happened. Anything kix does is at best "eventual" and at worst stale.
2. **Cross-namespace consumption is a property of the *cluster*, not the package.** The mechanism (reflector, CSI, operator-native publish) depends on what the cluster has installed, the same way storage classes depend on the cluster's CSI drivers.
3. **The producer should declare its consumers, not the consumer its producer's namespace.** kix already has this information from the DI graph. We can invert it at fixpoint and let the producer-side package or operator emit the right per-namespace artifact.

---

## Options

### A. Build-time literal copy
**Idea:** Inline the secret data into a second manifest at compile time.
**Verdict:** Impossible for `mkSecretRef` — no values exist. Listed only to retire it.

### B. One-shot deploy-time copy
**Idea:** `kix deploy` reads the source Secret from the live cluster and writes a mirror into the target namespace.
**Pros:** Trivial, no runtime component.
**Cons:** **Unrecoverable drift on rotation.** Defeats the purpose for any operator-rotated secret. Acceptable only for true bootstrap secrets that never change (registry pull secrets, static long-lived API keys).
**Verdict:** Keep as a clearly-labelled escape hatch with a scorecard warning. Not the default.

### C. Continuous mirror reconciled by the kix activation operator
**Idea:** kix's activation operator watches the source Secret and continuously updates the mirror.
**Pros:** Correct under rotation. No new dependency on a third-party reflector.
**Cons:** kix becomes a second writer competing with the source operator. RBAC must be granted cross-namespace. Latency between source change and mirror update is now a kix concern. Doubles the surface area where rotation bugs can hide.
**Verdict:** Possible, but it puts kix in a role that's better delegated.

### D. Delegate to a reflection operator (Reflector, kyverno, cluster-secret-replicator)
**Idea:** kix annotates the source Secret (`reflector.v1.k8ssandra.io/reflection-allowed=true`, `reflection-auto-namespaces=...`) and creates an empty placeholder Secret (or none) in the target namespace. The reflection operator does the actual copying.
**Pros:** Reuses well-tested existing infrastructure. kix stays out of the runtime data path. Correct under rotation. Same model as how we delegate certificate issuance to cert-manager.
**Cons:** Requires the cluster to have a reflection operator installed. Each reflector has slightly different annotation semantics — kix would need a small adapter per reflector, or pick one as canonical.
**Verdict:** Strong candidate when the cluster has the capability.

### E. Move the consumer to the producer's namespace
**Idea:** Sidestep the problem. Run immich in the `data` namespace next to postgres.
**Pros:** Eliminates the entire problem class. No copy, no mirror, no reflector.
**Cons:** Often unacceptable for separation-of-concerns / RBAC / quota / team ownership reasons.
**Verdict:** Worth surfacing in `kix diff` as a suggestion when cross-namespace count is small. Not a general answer.

### F. Don't copy — mount via CSI Secret Store
**Idea:** The consumer's pod uses a `SecretProviderClass` and the secrets-store-csi-driver to mount the secret directly from the producing operator (Vault, AWS Secrets Manager, or even another K8s namespace via the K8s provider). No Secret object in the target namespace at all.
**Pros:** **Eliminates the duplication entirely.** Single source of truth. Rotation propagates by next pod read or by sync interval. This is the technically cleanest answer.
**Cons:** Requires CSI driver. Doesn't work for `envFrom` consumers without the auto-Secret-sync feature, which itself recreates the duplication problem (though scoped and managed by the driver, not kix).
**Verdict:** The right answer when the cluster has CSI driver and the consumer mounts files. For env-var consumers, we still need a copy somewhere, and the CSI driver's auto-sync is the least-bad place for it.

### G. Producer-owned cross-namespace publish (operator-native)
**Idea:** The producing operator already knows about rotation. If it supports cross-namespace publishing (Stackgres' user CR with target namespace, cert-manager's `Certificate.spec.secretName` plus a `secretTemplate` with namespace targeting via wrappers), kix compiles to that mechanism. The operator both rotates *and* propagates. There is no second writer.
**Pros:** **No drift is even possible** — the same controller owns rotation and propagation. Matches the kix philosophy of "compile to the operator's native API."
**Cons:** Only works for operators that actually support cross-namespace publishing. Stackgres in particular currently does not (last we checked) — it manages secrets only in its own namespace.
**Verdict:** The ideal when supported. When not supported, we fall back to D or F.

### H. Capability-driven compilation
**Idea:** Tie this into doc 48 (system contracts) and doc 45 (hardware profile). The cluster declares its cross-namespace secret capabilities:

```nix
cluster.capabilities.secretPropagation = {
  reflector = "emberstack";       # or "none"
  csi.k8sProvider = true;
  default = "reflector";          # or "csi" or "fail"
};
```

At compile time, every cross-namespace `mkSecretRef` consumption is resolved against this capability. kix picks the right mechanism, emits the right manifests/annotations, and **fails the build** if no strategy is available.
**Pros:** Pushes the choice to the cluster operator (where it belongs), not the package author. Compile-time errors instead of runtime drift. Same philosophy as storage class selection.
**Cons:** More configuration for cluster operators. Requires kix to understand multiple propagation mechanisms.
**Verdict:** This is the right *frame*, with G/D/F/B as the strategies it picks between.

### I. Refuse cross-namespace consumption; force restructuring or explicit strategy
**Idea:** Make `mkSecretRef` strictly namespace-local. Cross-namespace consumption is a build error unless the cluster definer explicitly opts into a strategy per consumption site.
**Pros:** Forces the conversation to happen at design time. No accidental drift.
**Cons:** Friction. Users will hate it until they appreciate it.
**Verdict:** This is the *posture* H should take by default. Strict by default, opt-in to relax.

---

## Recommendation

**Combine H + I + G/D/F as the strategy menu.** Concretely:

1. **Make cross-namespace `mkSecretRef` consumption a compile error by default.** kix has the DI graph; it knows when a consumer in namespace `B` references a `mkSecretRef` whose source is namespace `A`. Surface this as a clear error, not a silent copy.

2. **Resolve via cluster capability.** The cluster declares `cluster.capabilities.secretPropagation` (doc 48 style). kix picks a strategy in this priority order:
   - **G — operator-native** — if the producing package advertises a cross-namespace publish mechanism (a `crossNamespacePublish` field in its `out`), use that. The operator handles rotation + propagation. Zero drift surface.
   - **F — CSI** — if the cluster has secrets-store-csi-driver and the consumer is volume-mounted, compile to a `SecretProviderClass`. No copy.
   - **D — reflector** — if the cluster has a reflection operator, annotate the source and emit the empty target mirror. The reflector handles propagation.
   - **B — deploy-time copy** — only with explicit `strategy = "static-copy"` opt-in *and* a `meta.rotation = "never"` declaration on the secret. Scorecard severity: warning. For bootstrap secrets only.
   - **Otherwise: build error** with a message that explains all four options and links to this doc.

3. **Producer declares, consumer queries.** A package that produces a `mkSecretRef`-style output (a wrapper around an operator that owns secret values) declares its propagation capability:

   ```nix
   out.credentials = scope.mkSecretRef {
     name = "stackgres-${scope.instanceName}-creds";
     keys = [ "username" "password" ];
     # Producer-side declaration: "I cannot publish cross-namespace"
     crossNamespacePublish = null;
     # If Stackgres later adds this support, change to:
     # crossNamespacePublish = { mechanism = "stackgres-cr"; ... };
   };
   ```

   The DI graph makes it trivial for kix to detect cross-namespace edges and pick a strategy.

4. **Surface drift risk in `kix diff`.** Any `static-copy` mirror is flagged as "this value is not reconciled — manual intervention required if the source rotates." `kix diff` against a live cluster can detect when a static-copy mirror has actually drifted.

5. **Document the producer-side fix path.** For Stackgres specifically: the right long-term answer is for the kix `stackgres-cluster` package to either (a) wrap a small controller that mirrors via Stackgres-aware events, or (b) push upstream for a `replicateTo` field on the user CR. Until then, reflector or CSI.

---

## What this gives up

- **Single-step "it just works" cross-namespace copy.** Users will hit a compile error the first time and have to either install a reflector, use CSI, or accept the static-copy escape hatch.
- **Pretending kix can be the source of truth for values it doesn't own.** This is good — the current temptation to make the kix operator a secondary reconciler is exactly what produces the unrecoverable drift the user is worried about.

---

## Open questions

### 78.1 Empty mirror vs annotation-only for reflector strategy
Different reflectors have different conventions. Reflector (emberstack) needs annotations on the source plus a placeholder Secret with a `reflects` annotation in the target. Kyverno's secret-replicator uses a ClusterPolicy. Do we pick one canonical reflector and document it, or build a small adapter layer?

### 78.2 How does the consumer's namespace get the *shape* (key list) at build time?
The consumer's manifest references `secret.out.keyRef "password"`, which expands to `secretKeyRef.name = "stackgres-…-creds"`. That `name` only resolves at runtime. At build time, kix only needs to know the *keys* (which we have from `mkSecretRef.keys`) and the *target name* in the consumer's namespace (which strategy D/F decides). Strategy F (CSI) doesn't even produce a Secret name — the consumer mounts a `SecretProviderClass`. We need an `out` API that abstracts over "give me an env var reference for key X in this namespace" without baking in the mechanism.

### 78.3 RBAC implications
Strategy D requires the reflection operator to have read access to the source namespace and write to all targets. Strategy F requires the CSI driver's service account to authenticate to the source. Strategy G (operator-native) is the only one that doesn't introduce a third party with cross-namespace secret read. Worth a row in the comparison table.

### 78.4 Interaction with `77_secret_access_control_modules.md`
Cross-namespace exposure is an access-control event. Doc 77 describes severity-tiered approval gates for access changes. A new cross-namespace consumption should flow through that approval gate — adding a new target namespace to a reflector annotation is a non-trivial access change. The two designs need to compose.

### 78.5 What about `mkSecret` mirrors?
Doc 74 §6's `mirrorOf` for `mkSecret` is *not* affected by this knot — kix owns the source. But for consistency, should `mkSecret` cross-namespace consumption also go through the capability layer (and just pick a "kix-native dual-hydrate" strategy when the source is `mkSecret`)? Probably yes, so the user-facing model is uniform: "cross-namespace consumption is a strategy choice, regardless of who owns the value."

### 78.6 Compile-time detection of "consumer is in another namespace"
Today, namespace assignment happens in the cluster definition, not the package. The compile-time check needs the resolved namespace map. This is easy at fixpoint but worth confirming we have it before the package's `build` function returns. Tied to doc 04 (namespace scope, archived) and how the current evaluator handles namespace propagation.
