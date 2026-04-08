# 79 — Operator-Backed Resources: Automatic Reconciler Edges

**Status:** Brainstorm
**Related:** `38_resource_type_tags.md` (capability-tag pattern via `mkCRD`/`mkCR`), `48_system_contracts.md` (DI for system services + `meta.provides`), `50_operator_crd_upgrades.md` (CRD ordering via content hashing), `35_crd_derived_rbac_webhooks.md` (derive-from-CRD pattern), `37_di_derived_network_policies.md` (post-eval DI-derived edges), `70_gateway_api_migration.md` (concrete consumer), `29_compiler-design.md`

---

## 1. The problem

A package that emits a Gateway, an HTTPRoute, an Ingress, a Certificate, or any custom CR is a **client of an operator**. The CR is just a row in etcd until something reconciles it into pods/services/routes. Today kix has no automatic edge from "this resource needs an operator" to "the operator must be deployed and Active first."

Concretely:

- `packages/n8n` calls `kix.expose` which emits an `Ingress`. ingress-nginx must be running for that Ingress to mean anything. Nothing in the dep graph forces ingress-nginx to be Active before n8n.
- The Gateway API migration (doc 70) makes this worse: `HTTPRoute` is even more obviously inert without a Gateway controller. The doc waves at this with "DI-provided capability" but never closes the loop on deploy ordering.
- `mkCR` already creates a content edge to the CRD (via `mkCRDRef` capability — doc 38 §4.1). It does **not** create an edge to the operator that owns the CRD.
- During first-time cluster activation this manifests as transient errors: CRs apply, get stuck Pending, eventually reconcile once the operator catches up. On a fresh kind/k3s spin-up it can deadlock if the operator package itself depends on something that depends on a CR.

What we need: when a package produces a resource of kind `X`, the compiler should automatically add a `requires`-edge to the package that **reconciles** kind `X`, so the activation operator (doc 43, 56) deploys the reconciler first and waits for it to be Active before applying the CR.

This is the sibling problem to doc 50 (CRD ordering) — that solves CRD-definition-before-CR. We need controller-deployment-before-CR.

## 2. What already exists (and what's missing)

| Edge | Mechanism | Status |
|---|---|---|
| CRD definition → CR instance | `mkCRD` exposes `out.mkCR`, which carries store-path context to the CRD | **Works** (38) |
| CRD upgrade ordering | Content-hashed CRDs with Established check | **Works** (50) |
| Cluster has *some* ingress controller | DI alias `ingressController` resolved at eval | **Designed** (48), partially built |
| Cluster has *some* DNS | `cluster.systemServices.dns` + `meta.provides` | **Designed** (48) |
| **Operator deployment → CR consumer (deploy ordering)** | — | **Missing** |
| **Built-in operator → consumer** (Ingress→ingress-nginx, LB Service→cloud-controller) | — | **Missing** |

The missing edges are the only thing that turns "DI says you have a controller" into "the controller's pods are Ready before you apply the CR that needs them."

## 3. Design space

Six options. They are not mutually exclusive — the right answer is probably (A)+(B) with (E) as the runtime backstop.

### Option A — Extend the CRD capability tag to carry its reconciler

Today `mkCRD` returns a resource whose `out.mkCR` builder carries a content edge to the CRD. Extend it: have `mkCRD` *also* know the package instance that owns the operator deployment, and have `mkCR` thread that into the produced CR's `requires`.

```nix
# packages/cert-manager/default.nix
crdCertificate = scope.mkCRD {
  group = "cert-manager.io";
  version = "v1";
  kind = "Certificate";
  reconciler = self.controllerDeployment;   # NEW
  ...
};

# packages/some-app/default.nix
cert = clusterIssuer.crdCertificate.out.mkCR scope { ... };
# → cert.requires automatically includes both:
#     - the CRD resource (existing)
#     - the cert-manager controller Deployment (NEW)
```

**Pros:**
- Zero new concepts. Reuses the existing capability-tag pattern from doc 38.
- The edge is intrinsic to the constructor — no post-eval pass, no scanning, no registry. "Make the error structurally impossible" (29 §7.4 level 1).
- Content hash flows naturally: bumping the operator image bumps every CR's hash, so the activation operator (56) reschedules consumers — which is exactly the right behavior, since a controller upgrade can change reconciliation semantics.

**Cons:**
- Only covers resources that go through `mkCR`. Doesn't help for built-in K8s kinds (Ingress, LoadBalancer Service, NetworkPolicy).
- `mkCRD` must be aware of "its" workload, which means CRD packages must wire their controller deployment back into the CRD constructor. Slight inversion — the CRD currently knows nothing about who runs it.
- Hash propagation may be too aggressive: every Certificate in the cluster reschedules when cert-manager bumps. Doc 50's content-hash logic already does this for CRD upgrades; this extends the blast radius. Probably fine, possibly want to tag certain reconciler edges as "ordering-only, no hash" (see §4).

### Option B — `meta.reconciles` on packages, post-eval edge injection

Symmetric to `meta.provides` from doc 48. Packages declare what they reconcile by `apiVersion/Kind`:

```nix
# packages/ingress-nginx/default.nix
meta.reconciles = [ "networking.k8s.io/v1/Ingress" ];

# packages/envoy-gateway/default.nix
meta.reconciles = [
  "gateway.networking.k8s.io/v1/Gateway"
  "gateway.networking.k8s.io/v1/HTTPRoute"
  "gateway.networking.k8s.io/v1/GRPCRoute"
];

# packages/cert-manager/default.nix
meta.reconciles = [ "cert-manager.io/v1/Certificate" "cert-manager.io/v1/Issuer" ];

# kube-controller-manager (built-in, modeled as a passthrough import on managed clusters)
meta.reconciles = [ "v1/Service[type=LoadBalancer]" "v1/PersistentVolumeClaim" ];
```

Then, in `buildCluster`, after instance evaluation, run a post-eval pass:

1. Collect every resource and its `apiVersion/Kind`.
2. Build a `kind → instance` index from `meta.reconciles` across all instances in the cluster.
3. For each resource, look up the reconciler instance and add a store-path edge from the resource to the reconciler's "ready" output (a chosen workload, e.g. the controller Deployment).
4. If no reconciler is found and the kind is not in the cluster's "managed" set (doc 48 capability), error.

**Pros:**
- Covers **everything**, not just CRs. Ingress, LoadBalancer Services, Certificates, Routes, custom CRs — all the same mechanism.
- Mirrors the doc 48 system-contracts shape: `meta.provides` for system services, `meta.reconciles` for resource kinds. Two facets of the same idea.
- The reconciler index doubles as the doc 48 layer 3 ("CRD-implied operator contracts") existence check. One mechanism, two checks.
- Built-in kinds (Ingress, LoadBalancer) work uniformly because the reconciler is just another instance with `meta.reconciles`. On managed clusters, a `kix.mkImport`-style passthrough instance (doc 65) declares `reconciles = ["v1/Service[type=LoadBalancer]"]` and stands in for the cloud controller.

**Cons:**
- Post-eval injection of store-path edges is the same machinery used in doc 37 for NetworkPolicies — proven, but not free. Slightly indirect compared to (A).
- Selector syntax for "Service with type=LoadBalancer" needs design (the `[type=...]` above is hand-wavy). Probably a small predicate DSL or just a dispatch function in the package.
- Multiple controllers reconciling the same kind (two ingress-nginx instances: public and private) need disambiguation. Default to: each package instance reconciles the resources it can be DI-resolved from. If a resource was exposed via `deps.ingressNginx = ref.public`, only the public instance is its reconciler. Falls back to (C).

### Option C — DI alias is the reconciler edge

The cleanest framing for "which reconciler handles this resource" is: **the same one DI already resolved**. When `kix.expose` is wired with `deps.gateway = ref.gateway-system.public`, the `public` Gateway is already the reconciler. The compiler just needs to promote that DI dep into a `requires`-edge on the produced HTTPRoute.

```nix
# Inside kix.expose's build entry:
(svc |> httpRoute.fromService { parentRef = gateway.out.gatewayRef; ... })
  |> scope.mkResource
  # NEW: build entry's DI deps automatically become requires-edges
  # on resources produced by that build entry
```

The mechanism: build entries (doc 62a) already declare their DI deps. The compiler adds a rule: any resource produced inside a build entry inherits a store-path edge to every DI dep that resolved to a non-null instance. That's an automatic per-build-entry "I depend on whoever wired me up" rule.

**Pros:**
- Zero new metadata. Uses information the compiler already has.
- Naturally handles multiple instances (public vs. private gateway): each `kix.expose` invocation is wired with one specific DI ref, and the edge follows that ref.
- Plays well with doc 70: HTTPRoute → its Gateway is exactly the right edge.

**Cons:**
- Only covers build entries. Direct `mkResource` calls in package bodies don't get automatic edges.
- Some DI deps are *configuration*, not *reconcilers* (e.g. `clusterConfig.ingress.host`). The build entry would need to mark which deps are "reconciler-of-my-output" — at which point you've reinvented (B) inside the build entry.
- Coarse: every resource a build entry produces gets the edge, even if some don't need it.

### Option D — Resource-scan inference via a hard-coded registry

Like doc 37's NetworkPolicy derivation: post-eval, walk all resources, look up reconcilers in a built-in compiler table:

```nix
# In lib (compiler builtin)
reconcilerRules = {
  "networking.k8s.io/v1/Ingress"            = { dep = "ingressController"; };
  "gateway.networking.k8s.io/v1/HTTPRoute"  = { dep = "gateway"; };
  "cert-manager.io/v1/Certificate"          = { dep = "clusterIssuer"; };
  "v1/Service" = res:
    if res.spec.type or "ClusterIP" == "LoadBalancer"
    then { capability = "loadBalancer"; }
    else null;
};
```

For each match, add a store-path edge to whichever instance satisfies the DI alias in the cluster.

**Pros:**
- Fully automatic from the package author's POV. No `meta.reconciles`, no `mkCRD` rewiring.
- Covers built-in K8s kinds where there's no CRD constructor to hang a tag on.

**Cons:**
- Hard-coded compiler table. Adding a new operator means patching kix internals — exactly the anti-pattern doc 48 §Approach 2 calls out ("the inference rules are hard-coded in the compiler").
- Doesn't extend to user CRDs without yet another mechanism.
- The DI alias rules are basically a duplicate of (B)'s `meta.reconciles` but living in the wrong place.

### Option E — Activation-time gate, not a compile-time edge

Push the problem to the activation operator (doc 43, 56). The operator already runs phase-based: Queued → Deploying → Active → Superseded. Add a phase rule: a resource of kind `X` is only applied once an instance with `meta.reconciles ⊇ {X}` is in phase `Active`.

No new compile-time edges; the operator just orders apply based on a runtime index of `meta.reconciles`.

**Pros:**
- Zero compile-time complexity. The DAG stays simple.
- Naturally handles dynamic cases (CRDs from Helm imports, externally-installed operators).
- Survives partial cluster updates: if the controller's status drops to NotReady, the operator pauses CR apply for that kind.

**Cons:**
- Loses the compile-time error. A cluster missing its ingress controller still *builds*; it just hangs at deploy time. Counter to doc 29 §7.4 (errors should be impossible, not detected at runtime).
- Content hash doesn't change when the operator does, so the activation operator won't re-apply CRs after an operator upgrade — sometimes correct, sometimes not.
- Best as a **backstop**, not the primary mechanism.

### Option F — Operator declares its consumers (inverted)

Operators advertise what they produce/own; consumers query the registry. This is just (B) with the direction inverted — operators register, consumers look up. Not meaningfully different from (B); listed for completeness.

## 4. Two kinds of edges: ordering vs. content

A subtle point worth pulling out before recommending anything. There are **two** things we might want from an "operator → consumer" edge:

1. **Activation ordering only.** "The controller must be Active before I apply." No content-hash linkage. Bumping the controller's image does *not* re-trigger the consumer.
2. **Full content edge.** Same as today's `mkCRDRef` chain. Bumping the controller bumps every consumer's hash.

Doc 50 (CRD upgrades) deliberately uses (2) for CRDs because schema changes can break CRs. For controller deployments, (2) is sometimes overkill: bumping ingress-nginx from 1.10.1 → 1.10.2 shouldn't reschedule every Ingress in the cluster.

Whatever option we pick, the edge type must be configurable. Default: **ordering-only** (1) for controller workloads, **full content** (2) for the CRD definitions themselves (already the case via doc 50).

## 5. Direction: C as primary, with a "manual escape" warning layer

The principle: **wire things with kix → get the edge for free. Bypass kix → get a compiler warning.** This collapses the design to a single rule and matches the compiler doc's level 1 → level 2 → level 3 fallback (29 §7.4).

### 5.1 Primary mechanism — option C

Build entries (doc 62a) already declare DI deps. Add a single compiler rule:

> Any resource produced inside a build entry inherits a store-path edge to every DI dep that resolved to a non-null instance, treated as **ordering-only** (see §4) on the DI dep's "ready" workload.

That's it. `kix.expose` wired with `deps.gateway = ref.public` produces an HTTPRoute that automatically requires the public Gateway to be Active. `kix.cert` wired with `deps.clusterIssuer = ref.letsencrypt` produces a Certificate that requires cert-manager to be Active. No `meta.reconciles`, no `mkCRD` rewiring, no post-eval scan. The edge is a side effect of the wiring the user already did.

Multi-instance disambiguation falls out: each `kix.expose` invocation is wired to one specific gateway ref, and the edge follows that ref. Public Gateway and private Gateway are distinct; HTTPRoutes attach to whichever one wired them.

The coarseness concern from §3 (option C) — "every resource a build entry produces gets the edge, even if some don't need it" — is fine. Build entries are small and purpose-built; their DI deps *are* their reconcilers by construction. If a build entry has a config-only DI dep that isn't a reconciler (e.g. `clusterConfig`), that's resolved at the build-entry-author level, not by tagging individual resources.

### 5.2 The "manual escape" warning layer

The hole in C: a package author who calls `scope.mkResource` directly to construct an Ingress, an HTTPRoute, a Certificate, or any CR — bypassing `kix.expose` / `kix.cert` / `mkCR` — gets no edge. Today this happens in `harbor` and `python-app` (raw Ingress manifests, doc 70 §4.1). It's exactly the case the doc 70 migration calls out.

Add a post-eval lint:

> For every resource whose `apiVersion/Kind` is in the "operator-backed" set, check whether it carries at least one ordering-edge to an instance with a matching reconciler capability. If not, warn.

The "operator-backed set" is small and stable:
- All CRs (anything not in core K8s API groups)
- `networking.k8s.io/v1/Ingress`
- `gateway.networking.k8s.io/*`
- `cert-manager.io/*`
- `v1/Service` with `spec.type ∈ {LoadBalancer, ExternalName}`
- (extend as needed)

The matching side needs a registry of *what reconciles what*. The minimal version: `meta.reconciles` on operator packages — same as option B in §3, but used **only as a lookup table for the warning**, not as the primary edge mechanism. Operator packages still need to declare what they reconcile so the lint knows what counts as "covered." But consumers don't have to do anything new — they just use the build entries, and the edge comes from C.

Warning text:

```
warning: package 'harbor' produces a raw Ingress 'harbor-portal' but
  no DI-derived edge to an ingressController instance was detected.

  This Ingress will be applied without ordering against the controller
  that reconciles it. On a fresh cluster activation it may hang until
  the controller catches up.

  Recommended fix: produce this Ingress via a build entry that takes
  `ingressController` as a DI dep (e.g. kix.expose), or call
  `scope.mkResource` from inside a build entry whose deps include
  the controller.

  Suppress: meta.allowUnlinkedReconcilable = [ "networking.k8s.io/v1/Ingress" ]
```

### 5.3 Why this is better than A/B/D

- **Single mechanism for the happy path.** No special-casing CRDs vs. built-in kinds — both flow through the same build-entry DI rule.
- **No new metadata in the common case.** Package authors never write `meta.reconciles` or `reconciler = self.controllerDeployment`. They just use `kix.expose` / `kix.cert` / `mkCR` and get edges.
- **The warning targets the actual smell.** "You called `mkResource` for a kind that has a reconciler" is exactly the case where the author opted out of the typed path. The lint pushes them toward the build entry rather than asking them to add yet another field.
- **Registry stays small.** `meta.reconciles` exists, but only operator packages set it (a closed set: ingress controllers, gateway controllers, cert-manager, custom operators). Consumer packages never touch it.
- **Doc 70 alignment.** This is exactly what doc 70's `kix.expose` story wants: app packages call the build entry, the migration is invisible, the controller wiring is the edge.

### 5.4 Backstop (option E) is still useful

The activation operator (doc 56) should still refuse to apply a resource of an operator-backed kind until *some* reconciler for that kind is Active in the cluster. This catches:

- Helm-imported resources where kix doesn't see the package wiring
- Bootstrapping races where the controller flaps
- The lint-suppressed cases (someone explicitly opted out)

Backstop is runtime; lint is compile-time; build-entry edges are the primary structural mechanism. Three layers, same level-1 → level-2 → level-3 ladder from 29 §7.4.

### 5.5 Levels in the 29 §7.4 ladder

| Level | Mechanism | Covers |
|---|---|---|
| 1 — Impossible | Build-entry DI → ordering edge (C) | Anything wired through `kix.expose`, `kix.cert`, `mkCR`, etc. |
| 2 — Detected at eval | Lint on raw `mkResource` of operator-backed kinds | Manual escape hatch usage |
| 3 — Warned at runtime | Activation operator refuses to apply without an Active reconciler in the cluster (E) | Helm imports, lint-suppressed cases, controller flaps |

Edges remain ordering-only by default (§4); CRD definitions stay full content edges via doc 50.

## 6. Open questions

1. **Which DI deps of a build entry count as reconcilers?** Not every DI dep is an operator. `clusterConfig`, `lib`, raw config blobs are not. Two options: (a) all non-null instance deps get the edge, configuration deps are filtered by type; (b) build entries explicitly mark which deps are reconcilers. (a) is simpler if we can cleanly distinguish "instance ref" from "config value" at the build-entry layer — and we mostly can, since instance refs come through the resolved DI graph and configs come through `clusterConfig`.

2. **What is the "ready" output of an operator package?** Some packages have one Deployment, some have a Deployment + a webhook + a CA injector. We need to designate which workload's Active health gates consumers. Likely an explicit `out.ready` field on operator packages, defaulting to "all workloads in the package." The build-entry rule from §5.1 then attaches the ordering edge to `dep.out.ready`.

3. **Hash semantics for ordering-only edges.** Do they appear in the content hash at all? If they don't, the activation operator needs a separate "ordering hint" channel from the content DAG. If they do, we're back to full hashing. Possibly: ordering edges live in a parallel `_ordering` set on the resource, fed to the operator alongside `requires`. This is the same plumbing question regardless of which option we picked, but it's load-bearing for C because every build-entry DI dep becomes an ordering edge.

4. **The lint's reconciler registry.** §5.2 needs `meta.reconciles` on operator packages so the lint knows what's covered. This is a *much smaller* surface than option B used it for — only operator packages set it, only the lint reads it. But the questions are similar:
   - Per-package or per-instance? (Probably per-package, since "envoy-gateway reconciles HTTPRoute" is a property of the package, not the instance.)
   - Selector syntax for "Service with `type=LoadBalancer`" vs. plain "Service"? Probably a small predicate function rather than a string DSL.

5. **What counts as "operator-backed" for the lint?** Hard-coded set in the compiler (small, stable: Ingress, Gateway API kinds, cert-manager, LB Services) plus auto-detection for any kind whose API group has a registered `meta.reconciles` provider. The auto-detection part is the interesting one — it means the lint widens automatically as new operator packages are added.

6. **Lint suppression.** `meta.allowUnlinkedReconcilable = [...]` on the consumer package. Audit-friendly, narrowly scoped per kind. Should it also be possible at the cluster level for "I know what I'm doing, this whole cluster has externally-managed cert-manager"?

7. **Helm-imported resources.** A Helm chart can produce CRs whose reconciler isn't visible to kix. The lint would fire on every such resource, which is noise. Options: (a) suppress lint for Helm-imported resources entirely, relying on backstop E; (b) let `fromHelmChart` accept a `linkedReconcilers = [ ... ]` arg that attaches edges to all imported resources at once.

8. **Interaction with doc 65 passthrough instances.** Managed clusters (GKE) have a built-in cloud controller for LoadBalancer Services. Modeled as a passthrough instance with `meta.reconciles = ["v1/Service[type=LoadBalancer]"]` and `out.ready` = constant-true. The build-entry DI rule still applies; the activation operator skips the readiness gate because there's no real workload.

9. **Multi-reconciler-for-one-kind in one cluster.** Two ingress controllers (public and private), both with `meta.reconciles ⊇ {"Ingress"}`. The build-entry DI rule handles this naturally: the consumer was wired with a specific ref, the edge follows that ref. The lint also handles it: as long as *some* DI-edge points at *a* reconciler for the kind, it's covered. No ambiguity.

10. **Should `kix.expose` be the canonical example?** Yes. It's the highest-leverage build entry, it's about to migrate to Gateway API (doc 70), and it's the perfect proof point for "wire with kix → free edges." Implement the build-entry DI rule there first, then migrate harbor / python-app off raw `mkResource` to silence the lint.

## 7. Next step

Two RFCs, landable independently:

1. **Build-entry DI ordering edges (option C)** — the structural mechanism. Smallest change, biggest payoff. Touches the build-entry compiler pass and adds `out.ready` to operator packages.
2. **Operator-backed resource lint** — the warning layer. Adds `meta.reconciles` to operator packages, defines the operator-backed kind set, runs as a post-eval pass. Depends on (1) to know what edges to look for.

Activation-operator backstop (E) is a third, separate RFC against doc 56 and can land in any order.
