# 85 — netpol.nix simplification

**Status:** Partially implemented (2026-04-09) — steps 2/3/4 from the revised plan landed; steps 1, 5–9 open.
**Related:** `37_di_derived_network_policies.md`, `82_cilium_package_and_netpol_di_wiring.md`, `83_netpol_via_crdref_and_scope_interception.md`

## Why this exists

`kix/lib/netpol.nix` has been restarted multiple times (RFC 37 → RFC 82 → the
accepted counter in 83). The current file is the landing of 83 Phases A and B.
It works, but it accumulated structure that made sense during the rewrite and
doesn't carry its weight now that DI is doing the heavy lifting. This doc
audits what's actually used, names the unused surface, and proposes a much
smaller shape.

The premise the rest of this doc takes as given:

- Cilium-only is fine. The file throws if no enforcer is resolved and we're
  happy with that — no pluggable backend, no abstraction layer.
- DI already builds the store-path DAG correctly. Every cross-package edge we
  care about is visible in workload-JSON string context at `mkDeployment`
  time.
- Breaking changes are free (per `CLAUDE.md`) — we can delete config options
  rather than deprecate them.

## What we built vs what we use

A feature-by-feature audit of the current file:

| Feature | Where | Used? |
|---|---|---|
| Per-workload egress CNP (DNS + service edges + StatefulSet self) | `buildWorkloadCnps` @ `netpol.nix:208` via `scope.mkDeployment` @ `scope.nix:828` | **Yes** — the core value. |
| Per-workload StatefulSet self-ingress CNP | `buildWorkloadCnps` selfIngress @ `netpol.nix:279` | **Yes** — needed for peer discovery. |
| Cluster-level inverted ingress pass | `generateIngressPolicies` @ `netpol.nix:557`, called from `cluster.nix` | **Yes** — only path for cross-instance ingress rules today. Phase C in doc 83 was going to replace this but was never implemented. |
| Default-deny per namespace | `generateDefaultDeny` @ `netpol.nix:648` | **Yes.** |
| CRD-ref routing (`cnpCrdRef.out.cr`) for every CNP | `buildCnp` @ `netpol.nix:42` | **Yes** — this is how CNPs get the cilium store-path edge. Core mechanism from 83 Phase A. |
| hostNetwork warning | `processInstance.warnings` @ `netpol.nix:537` | **Yes** — cheap and useful. |
| Helm opacity warning | same | **Yes** — cheap, useful. |
| `needsApiServerAccess` heuristic + apiserver-supplement CNPs | `processInstance` @ `netpol.nix:391, 467` | **Yes but crude.** Fires if *any* resource in the instance is RBAC/CRD/Role/…, then grants *all* non-hostnet workloads apiserver egress. Low precision. |
| `needsExternalIngress` heuristic + external-ingress-supplement CNPs | `processInstance` @ `netpol.nix:402, 500` | **Yes but crude.** Fires if *any* Service is LoadBalancer or *any* workload is hostNetwork, then grants *all* workloads `fromEntities = [ "world" ]`. Coarser than needed — the signals are local to the Service/workload in question. |
| `directions = "ingress" \| "egress" \| "both"` | `modules.nix:494`, threaded through every CNP emitter | **Under-used.** Doc 37 pitched a migration path (start ingress-only). No cluster in the repo has opted for anything other than `both`. Causes conditional branching in `buildWorkloadCnps`, `processInstance`, `generateIngressPolicies`, `generateDefaultDeny`. |
| `packageMeta.network.{allowExternalEgress, externalEgressEntities, extraEgress, extraIngress, externalIngressEntities}` | threaded through `scope.nix:839` → `buildWorkloadCnps.packageNetworkMeta` @ `netpol.nix:219, 274–283`; re-read in `processInstance.networkMeta` @ `netpol.nix:385, 526` | **Dead.** Grep across the repo: **zero packages** set any of these keys. Aspirational from RFC 37 that never got a consumer. Pure surface tax. |
| `_generatedNetpolEdges` sideband on workloads | `scope.nix:874` | **Yes** — read by cluster pass. But: `processInstance` *also* re-extracts the same edges from `allPartResources` (`netpol.nix:431–454`). Duplicate work. |
| Two separate edge extractors (`extractServiceEdges` vs `extractServiceEdgesFromJson`) | `netpol.nix:83–113` | **Redundant.** Exists because `buildWorkloadCnps` runs pre-build (no resource yet) and `processInstance` runs post-build. If we stop re-extracting in `processInstance`, we can delete the built-resource variant. |

Call the dead and under-used surface by name:

1. **`meta.network.*` has zero consumers.** Delete the whole block.
2. **`directions` is effectively always `both`.** Delete the option.
3. **`processInstance`'s edge re-extraction duplicates `_generatedNetpolEdges`.** Thread the sideband.
4. **The apiserver / external-ingress "supplements" are the only reason `processInstance` needs a whole-instance view.** If they move to local signals, `processInstance` becomes warnings-only.
5. **Two extractors collapse to one** once `processInstance` stops re-extracting.

## The local-signals thesis

> Every CNP this file emits can come from a signal that's local to a single
> resource at that resource's own build time. No post-fixpoint pass is
> required except the inverted-ingress aggregation (and Phase C's notes say
> even that can move).

Walking the cases:

**DNS egress** — constant, emitted per workload. Already local. ✓

**Cross-package service egress** — extracted from the workload's JSON
string-context at `mkDeployment` time. Already local. ✓

**StatefulSet self-egress / self-ingress** — local to the workload (kind +
selector). Already local. ✓

**Apiserver egress.** Currently: "any RBAC/CRD in the instance → all non-hostnet
workloads get apiserver egress." Three options, in order of radicality:

- **(a) Always grant.** Every non-hostnet workload gets `toEntities = [ "kube-apiserver" ]`.
  Rationale: apiserver access is low-risk compared to lateral pod-to-pod
  movement; network-policy isn't really the enforcement boundary for apiserver
  (RBAC is). Cost: one extra rule per CNP. Deletes the whole detection pass.
- **(b) Key on SA binding.** A workload needs apiserver iff its ServiceAccount
  is the subject of some RoleBinding/ClusterRoleBinding. Local-ish — the SA is
  visible on the workload, but the binding that references it is built
  elsewhere. Detectable at scope time iff the binding already exists when the
  workload builds, otherwise needs a post-pass (back to square one). Skip.
- **(c) Explicit opt-in on the workload.** Package author sets something like
  `needsApiserver = true` on the workload. Strict, locally visible, zero
  heuristic — but burdens package authors with something the compiler could
  just handle.

I lean **(a)**. It's boring, it's correct enough, and it deletes the most
code. The coarseness argument against it is weak: apiserver egress doesn't
open up lateral movement, and RBAC is the real gate.

**External ingress (LoadBalancer).** Currently: detected instance-wide, then
applied to every non-hostnet workload. But LoadBalancer is *visible on the
Service itself at its own build time*, and the backing workload is reachable
via the Service's `spec.selector`. The correct emission point is `mkService`
(new scope hook, mirroring `mkDeployment`): when a LoadBalancer Service is
built, emit an ingress CNP in that Service's namespace with
`endpointSelector.matchLabels = service.spec.selector` and
`ingress[].fromEntities = [ "world" ]`. Local signal, local emission.

Doc 83 Phase C already proposes `mkService` interception for a different
reason (label rendezvous), and the retraction notes in 83 suggest a simpler
"caller-side forNamespace" emission for the inverted-ingress problem.
Neither explicitly covered the LoadBalancer case, but `mkService` is the
right hook for both.

**External ingress (hostNetwork).** Currently: detected instance-wide, applied
to every non-hostnet workload (which is already wrong — the world-ingress
should be on the hostNetwork workload, but CNPs don't apply to host-network
pods, which is why we warn and skip). This supplement rule is effectively
dead: any workload that actually needs "world" ingress via hostNetwork gets
nothing from us, and we emit world-ingress CNPs on unrelated sibling
workloads. **Delete it.** Keep the warning.

**StatefulSet self-ingress** — already local. ✓

**Inverted cross-package ingress** (callers → target Service) — the
`generateIngressPolicies` pass. This is the one case where the target
doesn't know its callers locally. Options:

- **Keep the cluster-level pass.** Read edges from `_generatedNetpolEdges`
  (already collected sideband on each workload — no re-extraction). The pass
  itself is small. This is the status quo minus the duplication.
- **Phase C — caller-side emission.** Per 83's trailing notes: inside
  `buildWorkloadCnps`, for each discovered cross-package edge, emit *two*
  CNPs — the caller's egress (already emitted today) and an ingress CNP in
  the callee's namespace via `(scope.forNamespace targetNs).mkResource`.
  Both go into the caller workload's `extraDeps`. Deletes
  `generateIngressPolicies` entirely.

The trailing notes in 83 also flag a **required audit** before doing this:
"are there edges `generateIngressPolicies` catches today that scope-level
edge extraction would miss?" The cluster pass runs on `allPartResources ++
depResources`, so it sees in-package workload→in-package service refs that
scope-level might miss (because the scope-level edge extraction in
`buildWorkloadCnps` runs against `_netpolServiceRegistry` built from
`allPartResources ++ depResources` too, but *at workload-build time*, which
might precede some in-package service builds depending on `build` function
ordering).

This audit is the blocker on killing the cluster pass. It should be done
before Phase C, not as part of it.

## What the file looks like after

```
netpol.nix
├── buildCnp                        (unchanged — enforcer routing)
├── portsToCilium                   (unchanged)
├── mkServiceRegistry / isService   (unchanged — used by scope)
├── extractServiceEdgesFromJson     (the only extractor; built-resource variant deleted)
├── buildWorkloadCnps               (emits egress + self-ingress + ALWAYS apiserver egress)
├── buildServiceCnps                (NEW: emits LoadBalancer world-ingress at mkService time)
├── generateDefaultDeny             (unchanged)
└── generateIngressPolicies         (stays until Phase C audit; reads _generatedNetpolEdges, no re-extraction)

deleted:
- processInstance (warnings move to a one-shot pass or fold into instance.nix)
- extractServiceEdges (built-resource variant)
- apiServerSupplementPolicies / externalIngressSupplementPolicies
- needsApiServerAccess / needsExternalIngress signal detection
- apiServerEgressRule (inlined into buildWorkloadCnps' egress template)
- packageNetworkMeta plumbing through scope/instance/netpol
- directions plumbing
```

Config surface shrinks to:

```nix
networkPolicy = {
  enable = false;       # keep
  defaultDeny = true;   # keep
  # directions: DELETED (always enforce both)
};
```

Rough line count: `netpol.nix` drops from ~680 lines to somewhere around
~350. `scope.nix`'s netpol plumbing shrinks (no `packageNetworkMeta`
threading). `instance.nix` loses the `processInstance` call and related
warning collection.

## What collapses from the rest of the codebase

- `modules.nix:494` — delete `directions` option.
- `scope.nix:67, 839` — delete `peekedPackageMeta.network` reference.
- `scope.nix:828–845` — simplify; drop `networkConfig.directions` reads.
- `instance.nix:65` — delete comment about `meta.network.*`.
- `instance.nix` — delete the `processInstance` call site and fold its
  warning surface into a trivial inline pass (or drop into a
  `buildInstanceWarnings` helper).
- Any package-level docs mentioning `meta.network.*` — delete.

## Open questions

1. **Apiserver egress — always-grant (a) vs explicit opt-in (c)?** My lean is
   (a). The honest argument against is "it's a network policy that allows
   something we don't need." But the current heuristic allows the same thing
   to the same workloads in practice, just conditionally. The delta is only
   for instances with zero RBAC whose workloads somehow still need apiserver
   (rare, and if they do, we're silently denying today).

2. **`directions` — delete or keep for emergencies?** I argue delete. If
   someone wants ingress-only enforcement for a migration, they can set
   `networkPolicy.enable = false` per-cluster and write manual CNPs. The
   knob's "start with ingress, graduate to both" pitch from doc 37 never
   actually happened, and keeping it adds branching everywhere.

3. **Phase C: do the audit, then decide.** Phase C is attractive for the
   "one place owns the edge" reason but the status-quo-minus-duplication
   shape of the cluster pass is also fine. Not urgent. The right next step
   is the audit ("do in-package workload→service edges exist that
   scope-level misses?"), not the refactor.

4. **LoadBalancer ingress via `mkService`.** This requires a new scope hook.
   Do we add `mkService` now (for this one use case) or wait until Phase C
   also wants it? If we wait, the hostNetwork/LoadBalancer supplement
   deletion is still a win on its own — we just lose the proper
   LoadBalancer ingress CNP until there's a `mkService` hook. Acceptable as
   an intermediate state.

5. **Where do warnings go after `processInstance` dies?** Options: (a) fold
   into `instance.nix`'s existing warning collection, (b) a tiny
   `netpol.collectWarnings` helper called from `instance.nix` post-fixpoint,
   (c) emit via the new structured diagnostics system (doc 80). (c) is
   right long-term but shouldn't gate this simplification.

## Recommended sequencing

If this brainstorm graduates, here's a reasonable order of independent
landings. None of them are Phase C and none of them need the audit:

1. **Delete dead `meta.network.*` plumbing.** Pure deletion — no consumers.
   `scope.nix`, `instance.nix`, `netpol.nix`, `buildWorkloadCnps`.
2. **Delete `directions`.** Option, branches, conditionals. Pure deletion.
3. **Always-grant apiserver egress; delete `needsApiServerAccess` +
   supplement path.** Net line reduction in `processInstance`.
4. **Delete hostNetwork external-ingress supplement** (was wrong anyway).
   Keep the warning. Delete `needsExternalIngress`.
5. **Thread `_generatedNetpolEdges` into `generateIngressPolicies`; delete
   `processInstance`'s re-extraction and the built-resource
   `extractServiceEdges`.** One extractor remains.
6. **Collapse `processInstance` to warnings-only** (or inline into
   `instance.nix`).
7. *(Independent, later)* Phase C audit.
8. *(Independent, later)* `mkService` hook + LoadBalancer ingress CNPs.
9. *(Independent, later)* Phase C proper, if the audit clears it.

Steps 1–6 are strictly a simplification pass on what we have. None change
the set of CNPs emitted for a typical cluster except step 3 (which grants
apiserver to slightly more workloads — always a superset) and step 4
(which stops emitting a broken rule).

## What we're explicitly not reopening

- Whether to support non-Cilium backends. No.
- Whether `mkCRDRef`-based CNP routing (83 Phase A) was the right call. Yes;
  keep as-is.
- Whether scope-level interception (83 Phase B) was the right call. Yes;
  keep as-is.
- Whether Phase C's label rendezvous is the right design. No — 83's own
  trailing notes already retract it in favor of caller-side `forNamespace`
  emission.
