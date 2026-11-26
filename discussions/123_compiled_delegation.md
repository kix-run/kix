# 123: Compiled delegation — the drift-ignore surface

**Status:** Draft
**Related:** `122_runtime_content_drift.md` (the detection mechanism this policy layer serves), `121_netpol_as_plugin.md` (pre-seal-splice constraint), `120_compiler_theory_mapping.md` (staging vocabulary), `107_overlay_edge_exposure.md` (same intent-word DSL shape), `interesting_thoughts/83_package_owned_scorecard_rules.md`

Doc 122 detects drift by hashing the live object's kix-owned fieldset against
the stamp made at apply time. This doc answers the policy question that
raises: some fields are *supposed* to be written by other controllers (HPA on
`spec.replicas`, cert-manager on Secret `data`, operators on their own CRs'
spec). Which co-writes are legitimate, who decides, and how does the runtime
tell the difference — without a nix build?

## The compiled-delegation principle

> **Delegation is derived only from controllers inside the activation.
> kix owns the resource *and* the decision to delegate — delegation must be
> compiled, never inferred from whatever shows up live.**

kix owns the *declared envelope*, not every runtime value. K8s is built on
controllers legitimately co-writing objects — whole-resource ownership fights
the substrate and would flag kube-controller-manager on every autoscaled
workload. The declared program still fully governs the intent: the HPA CR is
kix-owned content, so its min/max/metrics drifting IS detected; only the
runtime-determined value floats, and it floats *inside declared bounds* (a
bounds check on live replicas vs the HPA's min/max is a natural extension).
But a rogue HPA someone kubectl-applied produces no delegation entry, so its
replicas take-over reports as ownership drift.

## Where the policy can live (and where it can't)

One constraint shapes the whole design: **a sealed resource cannot be
retroactively annotated.** Sealing (`builtins.toFile`) happens inside package
eval, and an HPA referencing `deploy.out.name` already depends on the sealed
workload — stamping the workload with knowledge of the HPA would make its
content depend on a resource whose content contains its own store path. This
is doc 121's pre-seal-splice constraint; no fixpoint closes that loop. So the
policy never lives on the workload manifest. Two patterns avoid it:

**Pattern 1 — authoring-time intent (dissolves the problem).** Autoscaling is
declared on the workload; the constructor emits the HPA:

```nix
web = scope.mkWorkload {
  kind = "Deployment";
  name = "web";
  autoscale = { minReplicas = 2; maxReplicas = 10; targetCpu = 70; };
  # constructor refuses `replicas` when autoscale is set, and emits the
  # HorizontalPodAutoscaler as a sibling resource wired to this workload
};
```

No cycle — the HPA depends on the sealed workload, never vice versa. The key
effect is *subtractive*: the Deployment is applied without `spec.replicas`,
kix never owns the field, the projection never includes it, and there is
nothing to ignore. The best drift policy is the one that doesn't need to
exist.

**Pattern 2 — assembly-time detection, carried on the PackageInstance.** For
raw or helm-imported HPAs (same or cross package), cluster assembly scans the
*sealed* resources — detection is read-only, so post-seal is legal — resolves
each delegation-table ref, and attaches the result to the **target's
PackageInstance**. The PI is constructed after all resources are sealed
anyway (it references them), so there is no ordering problem:

```nix
delegationTable = [
  { kind = "HorizontalPodAutoscaler"; ref = [ "spec" "scaleTargetRef" ];
    fields = [ "/spec/replicas" ]; }
  { kind = "ScaledObject"; ref = [ "spec" "scaleTargetRef" ];   # KEDA
    fields = [ "/spec/replicas" ]; }
];
# scan sealed resources → the *target's* PackageInstance gains:
#   spec.driftIgnore = { "Deployment/web" = [ "/spec/replicas" ]; };
```

Runtime resolution needs no build: every kix resource names its PI via
`kix.dev/package` + `kix.dev/package-namespace`; the checker GETs the PI
(cached in sweep/watch modes) and excludes the listed pointers from the
projection. The stamp side reads the same `spec.driftIgnore` from the
artifact. Because the PI is a manifest, the policy sits inside the activation
Merkle — changing it is a reviewable deploy.

The remaining layers ride the same carrier: package-shipped delegation
entries (operators writing back into their own CRs' spec, cert-manager
owning Secret `data` — doc 83b / doc 121 hooks) and the operator escape hatch
`cluster.drift.ignore = [{ target, jsonPointers }]` in the cluster definition
(same shape as Flux `.spec.driftDetection.ignore` / Argo `ignoreDifferences`,
but compiled onto the affected PIs). A scorecard rule
`architecture.delegatedFieldSet` warns when an HPA-targeted workload sets
`spec.replicas` explicitly ("remove it — an unset field is unowned and cannot
drift"), pushing packages toward pattern 1.

## How the runtime asserts the principle

Two independent directions, deliberately redundant: the field side catches
*effects* (any manager, any mechanism), the controller side catches *intent*
(the rogue CR sitting there, not yet acting).

**Field-side assertion** — the check's decision table for a foreign owner of
field P on resource R:

| Foreign managedFields entry | P in R's PI `driftIgnore`? | Verdict |
|---|---|---|
| subresource `status` | — | noise, never drift |
| spec write or `scale`-subresource write | yes (compiled delegation) | INFO "expected co-owner", P excluded from projection on both sides |
| spec write or `scale`-subresource write | no | **ownership drift**, attributed (manager, time, paths) |
| field kix never declared, no delegation claimed | — | out of scope (not in kix's fieldset, never hashed) |

The lookup key is the PI's `spec.driftIgnore` — compiled state, inside the
activation Merkle. Nothing observed live can grant an exemption; only a
deploy can. Implementation caveat: autoscalers and `kubectl scale` write
through the `/scale` subresource, so the attribution filter must exclude
*only* `subresource == "status"`, not all subresources — filtering all
subresources would blind the check to exactly the rogue-scaling case.

**Controller-side assertion** — `kix drift` additionally sweeps delegation-
capable kinds (the same table pattern 2 uses: HPA, ScaledObject) and resolves
each live instance's `scaleTargetRef` against kix-managed resources. A
targeting controller that itself carries no `kix.dev/identity-hash` is
reported as *"unmanaged controller targets managed resource"* — catching the
rogue HPA even before its first scale event transfers any field ownership.

## Staging

Patterns 1 and 2 don't conflict — they are compiler stages with **the seal as
the stage boundary**: anything that *changes manifests* (pattern 1's
desugaring of `autoscale` into an HPA + replicas removal) must run pre-seal;
anything that only *derives metadata over the whole program* (pattern 2's
delegation scan → PI `driftIgnore`) runs post-seal at assembly, like a
link-time pass (doc 120's vocabulary). Pattern 2 scans pattern-1-emitted HPAs
like any others, and stays necessary for raw, helm-imported, and
cross-package controllers.

Pattern 1 is the same DSL shape as `kix.expose` (doc 107): one intent word on
the workload, derived resources + declared delegation behind it. Exposure
personalities slot into pattern 2's table the same way — a package whose
controller co-writes kix-owned fields ships its delegation entry; children
those controllers *create* (proxy pods, provisioned Services) are not
kix-managed at all and sit outside drift scope (the operator-created-children
blindspot of doc 96, orthogonal to this design).

## Open questions

- **Delegation table contents**: HPA and KEDA are clear; what else earns a
  built-in entry vs package-declared? (VPA in `Auto` mode mutates *pods*, not
  the workload spec, so it likely needs nothing.)
- **Bounds checking**: should the field-side check evaluate delegated values
  against declared envelopes (live replicas within HPA min/max) in v1, or is
  ownership + delegation enough until a driver appears?
- **`cluster.drift.ignore` ergonomics**: target selectors (kind/name globs?)
  and whether operator-declared ignores should require a scorecard
  acknowledgment so they don't become permanent blind spots.
