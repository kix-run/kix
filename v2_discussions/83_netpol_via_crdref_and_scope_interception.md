# 83 — Netpol via mkCRDRef + scope-level workload interception

## Status

Draft (2026-04-09). Counter-proposal / refinement of RFC 82.

## TL;DR

RFC 82 is solving the right problem (CNPs must be store-path-ordered after
cilium, and workloads should be ordered after their CNPs) with the wrong
mechanisms. Two pieces of existing lib machinery already do the job — we just
aren't using them:

1. **`mkCRDRef` + `installedBy`** gives us "CNP → cilium" transitively, for
   free, without any resolver plumbing or `ciliumInstance` option. This
   replaces all of Part 1 of RFC 82.

2. **`scope.mkDeployment` / `mkStatefulSet` / `mkDaemonSet`** is the natural
   interception point for "workload → CNP" attachment. We intercept *before*
   the workload's `builtins.toFile` ever runs, so the CNP is in the workload's
   string context on the first (and only) build. No rebuild, no P1 wrapper
   shim, no P3 substitution pass, no P2 package-author opt-in. This replaces
   all of Part 2 of RFC 82.

3. Inverted ingress is a genuinely different problem and needs to be rethought
   rather than patched. Sketch at the end: **label rendezvous** replaces the
   cluster-level post-pass entirely.

No new DI primitive. No new config option. No new resolver semantics. No
capability-lookup RFC. Everything rides on mechanisms already in the lib.

## Why RFC 82's approach is overcomplicated

### The resolver detour

RFC 82 Part 1 proposes calling `resolveArg { argName = "cilium"; ... }` at
cluster evaluation time to find the cilium instance, then threading
`ciliumRef` as a hidden internal parameter through `processInstance`,
`generateIngressPolicies`, and `generateDefaultDeny`. The goal is a store-path
edge on every generated CNP pointing to cilium's `_packageInstance`.

But we are reinventing what `mkCRDRef` already does:

- `mkCRDRef` emits a PackageInstance import marker for a specific CRD. It has
  `installedBy` which takes a resource whose context is added to the marker's
  `requires`.
- `mkCRDBuilders` auto-adds the marker to every CR's `requires` list.
- The CLI's forward-closure walker already orders markers before their
  dependents, and markers gate on CRD `Established=True` readiness.

So if netpol emits CNPs via `cnpCrdRef.out.mkCR` instead of raw
`scope.mkResource { apiVersion = "cilium.io/v2"; kind = "CiliumNetworkPolicy"; }`,
every CNP automatically depends on the CRD marker, which depends on cilium.
Transitively: CNP → CRD ref → cilium. Exactly the edge the RFC wants, with
zero new mechanism.

The only remaining question is: **where does `cnpCrdRef` come from?** Not
from `resolveArg` — from the cilium package itself. The cilium package
already uses `fromHelmChart` with `includeCrds = true`, so the CRDs are
resources in its output. We do one of two things:

- **(a)** Have the cilium package expose `out.cnpCrdRef` via `fromHelmChart`'s
  `rootOut` callback (this is exactly what the helm wrapper's `rootOut` is
  for — see the "Helm-wrapped packages can expose DI builders" architecture
  note). `rootOut` calls `scope.mkCRDRef { group="cilium.io"; kind="CiliumNetworkPolicy"; plural="ciliumnetworkpolicies"; installedBy = self.root; }`
  and returns `{ cnpCrdRef = ...; }`. Now any consumer who has a DI handle to
  the cilium instance can read `cilium.out.cnpCrdRef`.

- **(b)** Have the netpol pass itself call `scope.mkCRDRef` with
  `installedBy = <cilium instance>`. This still needs "find cilium", so we're
  back to resolveArg. Reject.

(a) wins. The cilium package owns the CRD, so it owns the ref.

### Who's asking for `cnpCrdRef`?

Not the package author. Netpol is cluster-wide policy, not per-package
opt-in (the RFC's own premise). The *scope* is what builds workloads, and
the scope is constructed per-instance with full access to `clusterConfig`
and the resolved dep map. At scope construction time, we look up "the
network policy enforcer" *once*, pull its `out.cnpCrdRef` (or whatever the
minimal surface is), and hand it to netpol emission.

Concretely: scope gets a new internal field `networkPolicyEnforcer` that is
either `null` (netpol disabled or no enforcer) or the resolved instance's
`out` projection exposing `cnpCrdRef`. The lookup is a single read from
`clusterConfig.instances.*` filtered by `meta.provides` containing
`"network-policy-enforcer"` (or the narrower key `"cnp-crd:cilium"`). No
`resolveArg` call, no hidden parameter threading, no new config option.

**Self-dep guard**: If the scope belongs to an instance whose own
`packageMeta.provides` contains the enforcer capability, the lookup returns
`null` for that scope and netpol generation is skipped entirely for cilium's
own workloads. Same logic as RFC 82 but two lines instead of twenty.

---

## Part 2 done right: intercept at `scope.mkDeployment`

### Why the RFC's options all fail

- **P1 (store-path rewriting shim)**: rejected in the RFC for the right
  reason — dual handles are a debugging nightmare.
- **P2 (in-build `kix.netpol` helper)**: rejected in the RFC for the right
  reason — converts cluster-level policy into per-package convention.
- **P3 (rebuild in `processInstance`)**: rejected here for a reason the RFC
  downplays. The rebuild has to happen *before* the package's
  `_packageInstance` is computed *and* before any cross-package reference to
  the original resource escapes. Phase-1/Phase-2 fixpoint ordering makes this
  very fragile. Every cross-package consumer (Service selectors, secret
  refs, configmap envFrom) captures store-path context the moment the user
  writes `postgres.out.secret` in their package — the post-hoc rebuild leaves
  those captures pointing at the wrong resource.
- **P4 (fall back to package-level)**: gives up workload granularity.

All four options take the fact as given that CNP generation happens at
cluster level in a post-pass. **It doesn't have to.**

### The actual interception point

`scope.mkDeployment` is called once per workload, inside the package's
`build` function. At the moment of that call:

- The workload's raw manifest is fully assembled by the user (selector,
  pod template, envFrom, volume mounts, image, etc.).
- The manifest's JSON already carries string-context for every cross-package
  resource it references (configmaps, secrets, services from deps).
- `scope` has `networkPolicyEnforcer` (from cluster-level DI, resolved once
  at scope init).
- `scope` has `clusterConfig.networkPolicy` (enable, directions, extraEgress…)
- `scope` knows the instance's `packageMeta`.

So the new flow inside `scope.mkDeployment`:

```
args  →  preliminary JSON (no CNP yet)
      →  extract service context from that JSON
      →  (if netpol enabled & enforcer present)
         build CNP via enforcer.cnpCrdRef.out.mkCR { ... }
              ⇒ CNP has `requires = [ cnpCrdRef ]` automatically
              ⇒ cnpCrdRef has `requires = [ cilium ]` automatically
      →  real mkResource call with
         extraDeps = args.extraDeps ++ [cnp]
      →  workload manifest JSON now includes the CNP in its context
         on the FIRST (and only) toFile call
      →  return workload resource, CNP escapes via a scope-side sink
```

Critically: **there is no "preliminary workload" escaping.** The preliminary
JSON is computed once to inspect context, then thrown away. The resource the
user gets back from `scope.mkDeployment` is the only workload that exists.
No identity bifurcation, no splicing, no substitution.

The CNP needs to appear in `allPartResources` too (so it gets serialized and
applied). That's handled by a scope-level sink: `mkDeployment` registers the
CNP into a list that `evaluateInstance` reads after `build` returns,
identical to how cluster-level derived resources are collected today. This
does add a tiny bit of scope state (a ref to an attrset that `build` can
dereference at the end), but it's local and non-invasive.

### Edge visibility

The one thing to verify: **can a pre-toFile JSON pass capture the same
service edges that today's post-closure pass captures?**

Today (`netpol.nix:extractServiceEdges`) walks
`builtins.getContext (builtins.toJSON workload.rawManifest)` and intersects
with a Service registry built from `allPartResources ++ depResources`. The
workload manifest's context captures every resource the user referenced in
the manifest.

Two cases:

1. **Cross-package edges** (workload in pkg A → service in pkg B): present
   in the manifest's context the moment the user writes
   `postgres.service.out.name` or similar. Visible at `mkDeployment` time.

2. **In-package edges** (workload → service in the same package): today,
   `processInstance` walks `allPartResources` and finds the in-package
   Service. But — looking at the actual code paths — in-package workloads
   rarely reference in-package services in their manifest. The convention is
   the inverse: the Service has a selector pointing at the workload. So
   there's no context from workload → service to extract in the first place.
   Today's pass doesn't find these edges either. We lose nothing.

3. **Workloads that reference in-package configmaps / secrets**: the CM/Secret
   is typically built before the workload in `build`, so its context is
   present in the workload JSON at `mkDeployment` time. These aren't Service
   edges anyway — they don't generate egress rules. Unaffected.

Conclusion: `mkDeployment`-time edge extraction is strictly ≥ today's
`processInstance`-time extraction for egress purposes. Zero regression.

### What `processInstance` becomes

After this refactor, `netpol.processInstance` shrinks to:

- The warnings pass (hostNetwork check, helm opacity warning).
- Default-deny emission (already cluster-level, unchanged apart from using
  `cnpCrdRef.out.mkCR`).

`egressPolicies` and `instanceIngressPolicies` generation both move into
scope-level helpers called from `mkDeployment/StatefulSet/DaemonSet`. The
inverted `generateIngressPolicies` is a separate story — see next section.

---

## Rethinking inverted ingress

### Current model and why it sits at cluster level

`policyEnforcementMode = "always"` means a packet needs both caller-egress
allow and callee-ingress allow. The caller knows its targets at build time;
the callee doesn't know its callers until the whole cluster is evaluated.
Today we handle this with `generateIngressPolicies` — a cluster-level walk
over all egress edges that inverts them into per-Service ingress CNPs.

RFC 82 struggles with inverted ingress because its store-path model depends
on rebuilding the Service *after* all callers have been discovered, which
re-creates the P3 cross-package-reference problem at Service level. The RFC
punts to "attach inverted-ingress CNPs to the namespace instead." That's
coarse enough to mostly defeat the point — a default-deny namespace with
ns-scoped ingress allow is barely a policy.

### The label rendezvous alternative

Stop enumerating callers. Use label matching so both ends can be generated
independently at their own build times:

1. **At caller's `mkDeployment`:** for each discovered egress target service,
   stamp a label on the pod template:
   `kix.dev/netpol-reach/<hash(targetNs, targetSvc)> = ""`.
   The hash is a stable function of the target's identity, computable from
   the store-path context alone.

2. **At callee's `mkService`** (new scope hook, mirroring `mkDeployment`):
   emit an ingress CNP with
   `fromEndpoints = [{ matchLabels = { "kix.dev/netpol-reach/<hash(self)>" = ""; }; }]`.
   The hash uses the same function — callee hashes its own identity.

3. **Both CNPs** are built via `cnpCrdRef.out.mkCR`, so both transitively
   depend on cilium.

4. **Workload's `extraDeps`** includes its egress CNP (from §"intercept at
   mkDeployment"); **Service's `extraDeps`** includes its ingress CNP (from
   the new `mkService` interception).

Result:

- No cluster-level post-pass. `generateIngressPolicies` is deleted.
- No cross-package reference ordering problem: caller and callee generate
  independently; the label hash is the rendezvous token.
- Per-workload / per-Service DAG granularity automatically: the Deployment
  depends on its egress CNP, the Service depends on its ingress CNP.
- Works uniformly for intra-namespace and cross-namespace calls.
- Adds one label per egress target per pod. In practice this is a handful of
  labels even for chatty services. Cheap.

Open question: **label cardinality on shared backends.** A popular service
(e.g. postgres with 30 callers) has one ingress CNP matching a
single-hash label. Fine. A single workload talking to 50 services stamps
50 labels. Still fine. Label churn on redeploy is bounded because the hash
is stable under the target's identity, not its store path — the same target
service name always hashes to the same label.

Caveats to investigate:

- **Headless services / StatefulSet pod DNS**: caller talks to pod DNS, not
  Service IP. The label rendezvous still works because the callee's pod
  template carries the same label (Service→Workload selector implies the
  workload pods inherit "I'm reachable as X").
- **External ingress** (LoadBalancer, hostNetwork): no label rendezvous
  possible. Falls back to today's `fromEntities = [ "world" ]` rule. Emitted
  at `mkService`-time for LoadBalancer, at `mkDeployment`-time for
  hostNetwork. Both are local decisions.
- **What if the callee service isn't a kix resource?** (e.g. kube-apiserver).
  Detected today via the RBAC/CRD heuristic; stays the same. Caller emits
  `toEntities = [ "kube-apiserver" ]` in its egress CNP.

This design is genuinely out-of-the-box relative to RFC 82, which is why
I'm flagging it as a separate thread. Land the first two pieces without
blocking on this.

---

## What lands in each phase

### Phase A: `mkCRDRef`-based CNP wiring (replaces RFC 82 Part 1)

1. `kix/packages/cilium/default.nix`: pass `rootOut` to `fromHelmChart` that
   returns `{ cnpCrdRef = scope.mkCRDRef { group="cilium.io"; kind="CiliumNetworkPolicy"; plural="ciliumnetworkpolicies"; installedBy = self.root; }; ... }`
   (+ siblings for `CiliumClusterwideNetworkPolicy` if needed).
2. `kix/lib/eval/scope.nix`: at scope init, resolve the enforcer via
   `clusterConfig.instances` filtered by `meta.provides ∋
   "network-policy-enforcer"` (or `"cnp-crd:cilium"`); store the resolved
   `out.cnpCrdRef` on the scope (or `null`). Self-dep guard via
   `packageMeta.provides`.
3. `kix/lib/netpol.nix`: replace every `scope.mkResource { apiVersion =
   "cilium.io/v2"; kind = "CiliumNetworkPolicy"; ... }` with
   `scope.networkPolicyEnforcer.cnpCrdRef.out.mkCR { ... }`. Drop the
   `ciliumInstance` / `ciliumDeps` plumbing.
4. `kix/lib/modules.nix`: delete `networkPolicy.ciliumInstance` option.
5. Update `fromHelmChart` docs if `rootOut` needs any extension to cover the
   CRD-ref pattern (should be zero change — it already returns arbitrary
   attrs).

**Success criterion**: a cluster with a `cilium` instance → every generated
CNP has store-path context → cilium's CRD marker → cilium. A cluster without
a cilium instance and `networkPolicy.enable = true` → clean error pointing at
the missing enforcer capability (from the scope-init lookup, not from
`resolveArg`).

### Phase B: scope-level workload interception (replaces RFC 82 Part 2)

1. `kix/lib/eval/scope.nix`: factor `mkDeployment`, `mkStatefulSet`,
   `mkDaemonSet` to:
   - build preliminary JSON via an internal `prepareWorkloadManifest` helper
   - extract service edges from its context
   - call a new `netpol.buildWorkloadCNPs` (moved out of `processInstance`)
   - do the real `mkResource` with `extraDeps += cnps`
   - register CNPs into a scope-level sink list
2. `kix/lib/eval/instance.nix`: read the scope's CNP sink after `build`
   returns and append to `allPartResources`. Delete `_networkPolicies`
   intermediate.
3. `kix/lib/netpol.nix`: move `egressPolicies` / `instanceIngressPolicies`
   generation into small pure helpers called from the scope hooks.
   `processInstance` keeps only warnings + default-deny.
4. Regression tests against the existing cluster fixtures
   (`cluster-nw1`/`cluster-ludo`/`cluster-immich`): per-workload graph shows
   `Deployment → CNP → cnpCrdRef → cilium`.

**Success criterion**: `nix-store -q --deriver` on a cluster Activation,
followed by a tree walk, shows every workload transitively depending on its
own CNPs and on cilium. No rebuild, no substitution, no dual handles.

### Phase C: inverted ingress via label rendezvous (replaces RFC 82
"Ordering issue for inverted ingress")

1. Spec the hash function (`sha256(targetNamespace + "/" + targetService)`,
   truncated — exact shape TBD).
2. Add `mkService` interception (or reuse existing `scope.mkResource` with
   kind detection) to emit ingress CNPs at Service build time.
3. Extend `mkDeployment`/etc. to stamp pod-template labels per discovered
   egress edge.
4. Delete `generateIngressPolicies` entirely.
5. Delete the namespace-level inverted-ingress fallback.

**Success criterion**: remove `generateIngressPolicies` from cluster.nix with
no regression in the kix-diff of existing clusters (modulo the shape of the
ingress CNPs — now one per Service instead of one per target-Service tuple,
which is an improvement).

Phase C is independent of A and B and can be deferred if label rendezvous
turns up a subtle issue during prototyping.

---

## What we explicitly are NOT doing

- **No `resolveArg` for cilium.** The enforcer lookup is a one-line
  `filter-by-provides` against `clusterConfig.instances`, at scope init.
- **No new `kix.netpol` helper.** Package authors write `scope.mkDeployment`
  exactly like today; the netpol machinery is invisible.
- **No workload rebuild.** The workload is built once, correctly, the first
  time.
- **No RFC-82-style "store-path rewriting wrapper" (P1)** or "splice in
  `instance.nix` (P3)".
- **No new user-facing config option.** `networkPolicy.ciliumInstance` is
  deleted. `networkPolicy.enable` + presence of an enforcer instance is the
  full user surface.
- **No new capability-lookup RFC** (RFC 82 "Related work" mentions this as
  eventual). We don't need it: `mkCRDRef` already solves the CNP case, and
  other cases can adopt the same pattern on their own schedule.

---

## Risks / things to verify before committing

1. **Scope-level CNP sink state.** Adding write-side state to the scope
   (mutable list of emitted CNPs) is a small but real deviation from the
   "scope is pure" discipline. Need to confirm it plays well with Phase-1
   introspection (where the scope is called for side-effects during dep
   resolution). Probably fine — introspection doesn't call `mkDeployment` —
   but worth grepping.
2. **`fromHelmChart` `rootOut` access to `scope.mkCRDRef`.** Need to confirm
   `rootOut` receives a `scope` arg and that `scope.mkCRDRef` is fully
   available at that point. Per the architecture.md note, `rootOut` does
   receive `scope`. Should just work.
3. **Pre-toFile JSON extraction performance.** We'd do an extra
   `builtins.toJSON` call per workload to read context. Negligible
   (workloads are small; JSON-ification is cheap; `getContext` is cheap).
4. **Label collisions** in Phase C: need a hash length that's small enough
   to read in `kubectl describe pod` but large enough to not collide across
   a cluster's Services. 8 hex chars (32 bits) is fine for <10k services.
5. **Phase-2 pre-hint discovery.** RFC 82's concern about `self.foo` still
   returning the right workload doesn't apply here — there's no "other
   workload" for `self.foo` to be confused with.

---

## Open questions for the user

1. **Enforcer capability name.** `"network-policy-enforcer"`? `"cnp"`?
   `"cilium"`? Leaning `network-policy-enforcer` since it's dataplane-
   agnostic (Calico, nftables-based, whatever) and the `cnpCrdRef` is the
   specific thing we read off `out`.
2. **Multiple enforcers.** If a cluster declares both cilium and calico
   (unlikely but possible in a migration), which wins? Probably an error
   at scope init — same as `resolveArg`'s current ambiguity handling.
3. **Phase C timing.** Land A+B first, then design C as a separate doc? Or
   prototype C alongside B to validate the label-rendezvous end-to-end?
   Leaning toward A+B first for clean incremental landings.

---

## Related

- RFC 37 — DI-derived netpol (original design; this doc refines the emission
  site and the cilium-edge mechanism without changing the derivation
  principle).
- RFC 82 — the proposal this one counters. Part 1 is obsoleted by `mkCRDRef`;
  Part 2's P3 is replaced by scope-level interception; the "Ordering issue
  for inverted ingress" is replaced by label rendezvous.
- `kix/lib/eval/scope.nix:mkCRDRef` — the already-existing mechanism this
  doc leans on.
- `kix/lib/helm.nix:fromHelmChart` `rootOut` hook — the already-existing
  mechanism for Helm-wrapped packages to expose DI builders (see
  architecture.md "Helm-wrapped packages can expose DI builders").

  # Notes on Phase C

  what are your thoughts on phase C now? Would you still use the same approach?                               
                                                                                                              
● Honest answer: label rendezvous was overengineered. I'd use a different approach now — and I'm less         
  convinced Phase C is urgent.                                                                                
                                                                                               
  What implementing B changed my mind about                                                                   
   
  1. Scope-level edge discovery is trivially symmetric. Phase B already has buildWorkloadCnps extracting      
  (targetNs, targetServiceName, ports, targetSelector) tuples from the raw JSON context. The same data is
  available the moment any resource is built — including a Service being built, and including a workload that 
  needs to emit policies targeting cross-package services. There's no chicken-and-egg the way I worried about
  in RFC 83.                                   
  2. In-package workload→service edges really don't exist. I was right about this but I hedged a lot. After B
  I can say it with more confidence: I didn't hit a single case across 7 clusters. The convention is          
  callee-knows-nothing; the caller's context carries everything.
  3. generateIngressPolicies's ordering problem was specific to RFC 82's rebuild design. It doesn't exist in  
  the Phase B shape. The cluster-level post-pass still works exactly as before, because scope-level emission  
  on the caller side doesn't mutate any Service.
                                                                                                              
  So the "must kill inverted ingress" framing in RFC 83 was partly me projecting RFC 82's problems forward.   
  They don't carry over.                       
                                                                                                              
  The simpler shape I'd use instead of label rendezvous                                                       
                                               
  Emit the ingress CNP caller-side, in the callee's namespace, via scope.forNamespace.                        
                                                                                                
  Inside buildWorkloadCnps, for each discovered cross-package service edge, emit two CNPs:                    
                                                                                                
  1. The caller's egress CNP (current Phase B behavior) — lives in caller's namespace, in the caller          
  workload's extraDeps.                                                                         
  2. An ingress CNP in the callee's namespace: endpointSelector = edge.targetSelector, ingress[].fromEndpoints
   = { matchLabels = callerSelector; "k8s:io.kubernetes.pod.namespace" = callerNs; }, extraDeps = [           
  edge.service ]. Name: ${callerInstance}-to-${callerWorkload}-${targetService}-ingress so multiple callers
  don't collide on the same callee.                                                                           
                                                                                                
  Built via (scope.forNamespace targetNs).mkResource so it ends up with the right namespace and gets stamped  
  with labels from the caller's instance context (which is correct — the caller package "owns" the permission
  grant).                                                                                                     
                                                                                                
  Both CNPs go into the workload's extraDeps, so the caller workload waits for both its egress policy and the 
  paired ingress policy to land. N callers × M targets → N·M ingress CNPs — but each is tiny, and realistic
  clusters land ~100–200 total, same order as generateIngressPolicies emits today.                            
                                                                                                
  Why this beats label rendezvous              

  - No hash function, no cardinality reasoning, no pod-label pollution. Reach labels on every pod always felt 
  grubby. Pods get enough noise already.
  - Plain Kubernetes semantics. fromEndpoints.matchLabels with explicit selectors is what operators already   
  read and debug. A hashed kix.dev/netpol-reach/<8-hex> label is opaque.                                      
  - Symmetric with egress emission. Both CNPs come out of the same edge loop in buildWorkloadCnps. The helper
  barely grows.                                                                                               
  - Cross-namespace ownership is already a solved pattern. scope.forNamespace exists and is used by e.g. the
  reflector workflow. No new primitive.                                                                       
  - Label rendezvous' "both sides independently compute the same hash" property turns out not to be worth 
  much. In Phase B the caller already has the full callee identity (it's how we discovered the edge).         
  Rendezvous was only attractive when I was imagining the callee emitting its ingress CNP without knowing
  callers — which only matters if we're doing it at callee-build time. We're not; we're doing it at           
  caller-build time.                                                                            
                                               
  What the callee side looks like                                                                             
  
  Nothing. scope.mkResource { kind = "Service"; ... } stays untouched. No mkService interception, no          
  reach-label generation. The only thing that changes is: more CNPs show up in the callee's namespace, owned
  by the caller instance.                                                                                     
                                                                                                
  The one wrinkle: scope.forNamespace returns a scope in the target namespace but keeps instanceName of the   
  caller. That's what we want — labels on the emitted CNP say app.kubernetes.io/instance = <caller> which
  correctly identifies provenance. Need to verify forNamespace preserves instanceName (it does, looking at    
  scope.nix:1151 — inherit instanceName).                                                       
                                               
  Is Phase C still worth doing?

  Less urgent than I argued in RFC 83. Here's what we get vs. what we keep:                                   
  
  Keep generateIngressPolicies (status quo after Phase B):                                                    
  - Works. The RFC 82 P3 ordering problem never materializes.                                   
  - Cluster-level walk reads _networkEdges from each instance, emits one ingress CNP per target Service       
  aggregating all callers.                                                                             
  - Compact: 1 CNP per target Service, not N·M.                                                               
  - Downside: the callee's ingress CNPs don't gate callee readiness. Brief unenforced window when callee
  starts before all caller-originated ingress policies land. Small and transient.                             
                                                                                                              
  Phase C (caller-side emission):                                                                             
  - Deletes the cluster-level pass. Fewer moving parts; cluster.nix shrinks.                                  
  - Per-callee readiness gate for ingress — closes the reverse window.                                        
  - More CNPs (N·M instead of M), but each trivial.                   
  - Per-package ownership of ingress permissions — reads naturally in kubectl describe cnp ("which package put
   this here" = the one whose instance label is on it).                                                       
                                                                                                              
  Honest tradeoff: the readiness-window argument is real but quantitatively minor. The compactness argument
  cuts in favor of status quo. The "one place that owns the cross-package edge" argument cuts in favor of     
  Phase C.                                                                                      
                                                                                                              
  What I'd actually do                                                                          
                                               
  1. Land a small cleanup first: move per-edge ingress emission into buildWorkloadCnps, produce both CNPs, but
   keep generateIngressPolicies running for now. Measure duplication. If they produce identical rules (which
  they should), delete the cluster-level pass in a second PR. If there's a mismatch (e.g. default-deny        
  fallback cases, cross-package edges that scope-level misses because the dep isn't in resolvedDepMeta), keep
  the cluster pass as a backstop.              
  2. Drop label rendezvous entirely from the plan. It was clever but the cleverness doesn't pay for itself.
  3. Update RFC 83 Phase C section to reflect the caller-side-forNamespace design and tone down the urgency.  
  The doc currently makes it sound like Phase C is the natural next step. After B, it's more like a           
  nice-to-have refactor.                                                                                      
                                                                                                              
  The thing I'd want to verify before committing to even this simpler Phase C: are there edges that           
  generateIngressPolicies catches today that scope-level edge extraction in B would miss? The _networkEdges
  feeding the cluster pass comes from processInstance which runs against allPartResources ++ depResources — so
   it sees in-package workload→in-package service refs that scope misses. If any package has those (even one
  case), the cluster pass must stay or Phase B's scope-level registry has to grow to include in-package
  resources. I haven't audited that, and I should before deleting anything.

  Short version: yes to Phase C conceptually, no to label rendezvous, not urgent, and audit _networkEdges     
  first.
