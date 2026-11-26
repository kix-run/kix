# 82 — Cilium Package + DI-Wired Netpol Dependencies

## Status

Draft (2026-04-09). Follows up RFC 37 (DI-derived network policies).

## Problem

`kix/lib/netpol.nix` emits `CiliumNetworkPolicy` resources from the DI graph
(RFC 37). Those resources are useless without two things in the cluster:

1. The Cilium CRDs (`CiliumNetworkPolicy`, `CiliumIdentity`, etc.) must be
   installed.
2. A running `cilium-agent` DaemonSet + operator must enforce them.

Today nothing in the DAG guarantees either. A user can enable
`networkPolicy.enable = true` on a kubeadm cluster with no CNI, get a pile of
valid-looking CNP YAML out, and be surprised when applying them fails (no CRD)
or succeeds but is never enforced (no agent). Cilium has to appear in the
resource graph *and* be ordered before any CNP in the deploy wave.

The first cut (see branch) added an explicit user option
`networkPolicy.ciliumInstance = config.instances.kube-system.cilium._packageInstance`
and threaded it through netpol.nix. That works but has three smells:

- User has to know and hand-wire the reference.
- No error when the user enables netpol but forgets cilium.
- Nothing prevents the reference from pointing at the wrong thing.

We want the same result to fall out of DI automatically.

## Goal

- Declare a `cilium` package instance anywhere in the cluster → every generated
  CNP automatically depends on it, and cilium lands in an early deploy wave.
- Enable netpol without cilium → DI-shaped error at evaluation time.
- Zero user-facing plumbing. No new config option.
- Workload-level DAG precision: CNPs attach to the workload (or Service) that
  needs them, not as a loose package-level collection.

## Non-goals

- Replacing the cilium helm chart with a native kix package (the current
  `kix/packages/cilium/default.nix` uses `fromHelmChart`, and that's fine).
- Generalizing `meta.provides` into a full capability-lookup mechanism. That's
  the right eventual shape but is a separate RFC (it touches the resolver
  semantics).
- Supporting non-cilium enforcers in this RFC. Calico hooks are noted in
  "Future work" but not implemented.

## Design overview

Two independent changes, stacked:

1. **Resolver-driven cilium lookup.** One call to `resolveArg` at cluster
   evaluation time finds the cilium instance via the existing resolution
   index. Missing cilium → standard DI error. Result is threaded into
   `netpol.processInstance`, `generateIngressPolicies`, and
   `generateDefaultDeny` as an internal (non-user-facing) parameter.

2. **Resource-level attachment of CNPs.** Today `processInstance` returns a
   list of CNP resources that instance.nix collects into a package-level
   `_networkPolicies` bag. Consumers (the CLI, the operator) see policies as
   siblings of the workload — the package "owns" them, but the workload
   doesn't structurally require them. This RFC moves the attachment edge down:
   the workload (and the Service, for inverted ingress) directly declares the
   CNP in its dep closure, so "workload ready" means "its policies are
   applied by a running cilium."

The two changes are independent. (1) can land first and unblock clean cilium
wiring; (2) is a follow-up that sharpens the DAG granularity.

---

## Part 1: Resolver-driven cilium lookup

### Cilium package (already exists, extend docs)

`kix/packages/cilium/default.nix` follows the helm-wrapper pattern
(`{ meta, chart, defaultValues }`). Key contract for this RFC:

```nix
meta = {
  provides = [ "cni" "network-policy" "cilium" ];
  # ...
};
```

The `"cilium"` entry in `provides` is the marker used by the self-dep guard
(see below). Convention: instances are named `cilium` or carry
`aliases = [ "cilium" ]`. Same convention as `dns` / `storageClasses` /
`clusterIssuer` platform deps.

### Resolution in cluster.nix

In `kix/lib/eval/cluster.nix`, after `buildResolutionIndex` and after
`allInstances` is available, resolve cilium once:

```nix
ciliumRef =
  let
    needed =
      networkConfig.enable
      && (cfg.cluster.capabilities.networkPolicyAPI or "none") == "cilium";
  in
  if !needed then null
  else
    let
      r = resolveArg {
        argName = "cilium";
        requesterNamespace = "kube-system";
        hasDefault = false;
        explicitOverride = null;
        inherit resolutionIndex;
      };
      inst = allInstances.${r.namespace}.${r.instanceName};
      isImport = inst._meta.isImport or false;
    in
    # Imported cilium (e.g. flavor-provided for RKE2/GKE dataplane-v2) has no
    # store path to depend on — treat as "platform-provided, no edge needed."
    if isImport then null else inst._packageInstance;
```

`resolveArg` already throws
`no 'cilium' found in cluster for namespace 'kube-system'` when no instance
exists — that's the error we want, no new code needed.

`ciliumRef` is then threaded as an internal argument into:

- `netpol.processInstance` (per-instance, called from instance.nix)
- `netpol.generateIngressPolicies` (cluster-level inverted ingress)
- `netpol.generateDefaultDeny` (cluster-level default-deny)

### Self-dep guard

The cilium package's own workloads should not depend on themselves. In
`processInstance`:

```nix
isSelfCilium = builtins.elem "cilium" (packageMeta.provides or [ ]);
effectiveCiliumRef = if isSelfCilium then null else ciliumRef;
```

Cluster-level resources (default-deny, inverted ingress) never match the
cilium package, so they always receive `ciliumRef` directly.

### Deletions

- Delete `networkPolicy.ciliumInstance` option from `kix/lib/modules.nix`.
- Delete the corresponding read in `netpol.nix` and the pass-through in
  `cluster.nix`. Replace with the internal `ciliumRef` flow above.

### Error shape (desired)

```
$ nix build .#cluster-foo
error: no 'cilium' found in cluster for namespace 'kube-system'
  networkPolicy.enable = true and capabilities.networkPolicyAPI = "cilium",
  but no instance named 'cilium' (or aliased 'cilium') was declared.
  Add one from kix/packages/cilium, or set networkPolicyAPI to match your
  actual enforcer.
```

(The first line is the bare resolver error. The hint block is added by
wrapping the resolveArg call with a `builtins.tryEval`-catch in cluster.nix.)

### Generalizing to other enforcers

The lookup key is a single-site choice:

```nix
enforcerArg = {
  cilium  = "cilium";
  calico  = "calico";
  k8s     = null;      # no enforcer resource needed
  none    = null;
}.${cfg.cluster.capabilities.networkPolicyAPI or "none"};
```

Only cilium is implemented in this RFC. Calico is a drop-in later.

---

## Part 2: Workload-level attachment of CNPs

### Current state

`kix/lib/netpol.nix:processInstance` returns:

```nix
{
  policies = egressPolicies ++ instanceIngressPolicies;  # list of CNP resources
  edges    = allEdges;                                    # for cluster pass
  warnings = [ ... ];
}
```

`kix/lib/eval/instance.nix` collects `policies` into the per-instance
`_networkPolicies` list, which `cluster.nix` folds into `allPartResources` via:

```nix
++ (inst._networkPolicies or [ ])
```

The CNP's own `extraDeps` today is:
```nix
extraDeps = [ w ] ++ map (e: e.service) we.edges;
```

This gives the CNP a dependency on its target workload and on every Service it
mentions (so the workload and services exist before the policy evaluates).
It does **not** give the workload a dependency on the CNP.

Net effect: the package instance bundles workload + CNPs as siblings. At
deploy time, the CLI/operator applies them in store-path order, which puts
the workload before the CNPs (CNP depends on workload). The workload can
become "ready" before its policies are in place — a brief unenforced window.

### Target state

The user's model: **the workload "needs" the policy to operate, and the
policy "needs" cilium to operate.** The DAG should be:

```
Deployment / StatefulSet / DaemonSet
  │  ← new edge: workload depends on its own CNPs
  ▼
CiliumNetworkPolicy (egress / ingress / self)
  │
  ▼
cilium._packageInstance   ← Part 1
```

For inverted cluster-level ingress (`generateIngressPolicies`), the edge
lives on the **Service**: the Service "needs" its ingress policy. For
default-deny, the edge lives on the namespace resource.

### The problem

Resources in kix are immutable after `mkResource`. By the time
`processInstance` runs, the workload has already been constructed inside the
package's `build` function. We cannot mutate `w.extraDeps` to add a CNP the
workload didn't know about.

Three options, in increasing invasiveness:

#### Option P1: Store-path rewriting via a wrapper resource

Introduce a thin "readiness shim" resource per workload: a new k8s-like
handle whose output is the same manifest as the underlying workload but whose
store-path context includes edges to all generated CNPs. The shim replaces
the workload in `allPartResources`; consumers who look up the workload via
`self.foo` still get the original; consumers walking `allPartResources` see
the shim.

- Pros: no mutation; shim is an opaque wrapper around existing resource.
- Cons: introduces a "double handle" for the workload. Debugging becomes
  confusing. The CLI's package index has to understand that workload-X-shim
  and workload-X map to the same k8s object.

**Verdict**: rejected. The divergence between `self.foo` and the
serialized resource creates subtle bugs.

#### Option P2: CNP generation moves earlier (inside build function)

Expose a `kix.netpol` helper that packages call inside their `build` function
(analogous to `kix.expose`). It takes the workload and a list of target
services, emits CNPs, and returns the workload **wrapped with the CNPs as
deps** — constructed in one pass, no mutation.

- Pros: clean data flow. The workload is built knowing its CNPs from the
  start. Matches the `expose` mental model the user likes.
- Cons: opt-in by package author. That breaks the "netpol is cluster-wide
  policy, not per-package feature" premise of RFC 37. Every existing
  package would need to be migrated.

**Verdict**: rejected. Converts a cluster-level guarantee into a per-package
convention. Anti-goal.

#### Option P3: Rebuild workloads in processInstance (chosen)

`processInstance` receives `allPartResources` and is already the single
authority on netpol emission. Extend it to:

1. Identify workloads.
2. Generate CNPs for each workload (as today).
3. **Rebuild** each workload by calling `scope.mkResource` with the same
   manifest plus `extraDeps = workload.extraDeps ++ its_CNPs`. The new
   workload resource shares the same kind/name/namespace — same k8s object
   identity, different store path.
4. Return the rebuilt workloads alongside the CNPs, so instance.nix can
   splice them back into `allPartResources`, replacing the originals.

The "splice" step requires a small change in instance.nix: after
`processInstance` returns, it walks `allPartResources` and substitutes any
workload whose `(kind, name, namespace)` matches a rebuilt workload from the
netpol result.

Key detail: `self.deployment`, `self.statefulset`, etc. as accessed by
other code inside the package remain the *original* workload references.
Nothing inside the package's build function sees the rebuild. Only the
serialized resource graph (what `collectResources` walks) sees the rebuilt
versions. This is the critical property that prevents Option P1's double-
handle confusion.

**Caveats**:

- Resources referenced *across* packages via store-path context need to see
  the rebuilt workload, not the original. Concretely: if another package
  references `postgres.workload.out.selector`, the returned selector is the
  same (labels are the same), and the context on it points to the *original*
  workload resource. We need it to point to the rebuilt one, otherwise the
  downstream consumer pulls in the original (without the CNP edge) instead
  of the rebuilt (with the CNP edge).
- Fix: the rebuild happens before `_packageInstance` is constructed. The
  package instance CR lists the rebuilt workload in its resources. Any
  downstream consumer that depended on the package (via its instance) gets
  the package instance's closure, which includes the rebuilt workload,
  which includes its CNPs. Transitivity still works.
- For direct resource-to-resource references across packages (e.g.,
  `ingress-nginx` referencing `my-app.service.out.name`), the reference is
  to the Service, not the workload. Services are not rebuilt in most cases.
  In the inverted-ingress case (cluster-level), the Service *is* rebuilt
  (to attach the ingress CNP). That rebuild must happen before any
  cross-package reference is resolved — meaning the inverted-ingress pass
  has to run before the cross-package closure is computed. Today it runs
  at cluster level after per-instance processing; see "Ordering" below.

#### Option P4: Give up and keep package-level collection (fallback)

If P3's rebuild proves too invasive, fall back to the current model where
CNPs sit in `_networkPolicies` and are bundled with the package. Part 1 of
this RFC still applies — every CNP depends on cilium. The only thing we
lose is workload-level DAG granularity. The package instance is the dep
root, and "package deploys after cilium" is a slightly coarser guarantee
than "workload deploys after cilium" but practically equivalent.

### Chosen path

**Land Part 1 first.** It deletes a user option, plugs a real error, and
provides the cilium edge at the CNP level. This alone closes the main gap:
applying cilium always precedes applying any generated CNP.

**Then attempt P3 for Part 2** in a follow-up PR. If the rebuild introduces
resource-graph surprises (especially around cross-package references),
fall back to P4 and accept package-level attachment. The cost of the
fallback is readiness granularity, not correctness.

### Ordering issue for inverted ingress

`generateIngressPolicies` runs at cluster level, after all instances have
been evaluated. Its CNPs are attached (in P3) to the target Service — but by
then, consumers of the Service may have already captured store-path
references to the original Service. Attaching the CNP edge after those
captures means the downstream consumer has the pre-rebuild Service and
misses the CNP edge.

Options:

- Run inverted-ingress generation in a *pre-pass* before cross-package
  resolution, and have instance.nix use the rebuilt Service. This requires
  restructuring the fixpoint.
- Accept that inverted-ingress policies attach to the namespace resource
  instead of the Service. Coarser but avoids the ordering problem.

**Recommendation**: in the first iteration, attach inverted-ingress CNPs to
the namespace resource (or cluster-level, dep on cilium only). Only per-
workload CNPs get workload-level attachment. Revisit if the coarseness is
a real problem.

---

## Implementation plan

### Phase 1: resolver-driven lookup (≈60 LOC)

1. `kix/lib/eval/cluster.nix`: compute `ciliumRef` after `resolutionIndex`
   and `allInstances` exist. Guard on `networkConfig.enable` +
   `capabilities.networkPolicyAPI == "cilium"`.
2. `kix/lib/eval/cluster.nix`: wrap the `resolveArg` call with a
   `tryEval`-catch to add a hint message. On success, extract
   `_packageInstance` (or null for imports).
3. `kix/lib/eval/cluster.nix`: pass `ciliumRef` into `generateIngressPolicies`
   and `generateDefaultDeny`.
4. `kix/lib/eval/instance.nix`: pass `ciliumRef` through to
   `netpol.processInstance` (new arg, sourced from clusterConfig closure).
5. `kix/lib/netpol.nix`: accept `ciliumRef` as explicit parameter (not via
   `networkConfig`). Add self-dep guard using `packageMeta.provides`.
   Append to `extraDeps` on every generated CNP.
6. `kix/lib/modules.nix`: delete `networkPolicy.ciliumInstance` option.
7. `kix/packages/cilium/default.nix`: already has
   `meta.provides = [ ... "cilium" ]`. Add a line to the header comment
   documenting the resolver convention (name it `cilium` or alias it).
8. `kix/lib/architecture.md`: note the new `ciliumRef` flow in the
   "Cross-cutting concerns → netpol" section.

**Tests**:

- A cluster with `networkPolicy.enable = true`, `networkPolicyAPI = "cilium"`,
  and a `cilium` instance → build succeeds, generated CNPs carry a store-
  path edge to the cilium `_packageInstance`.
- Same cluster without the cilium instance → build fails with a resolver
  error naming `'cilium'`.
- A cluster with `networkPolicyAPI = "k8s"` → no lookup, no error, no
  cilium edge (current behavior preserved for non-cilium clusters).
- The cilium package's own workloads (if it emits any via CNPs) → no
  self-edge (self-dep guard).
- An imported cilium (`mkImport` with `provides = [ "cilium" ]`) → resolves
  but returns null for `_packageInstance`, no edges added. Covers RKE2 /
  GKE dataplane-v2 platform-provided case.

### Phase 2: workload-level attachment (P3, ≈100-150 LOC, follow-up PR)

1. Extend `processInstance` to return `{ policies; edges; warnings; rebuiltWorkloads; }`.
2. Rebuild each workload inside `processInstance` using `scope.mkResource`,
   adding its CNPs to `extraDeps`.
3. `instance.nix`: splice rebuilt workloads into `allPartResources` (match
   by kind+name+namespace), before the package instance CR is constructed.
4. Verify that `self.<workload-name>` inside the package's build function
   is untouched (only the resource graph downstream of instance.nix sees
   rebuilt resources).
5. Regression tests: `cluster-nw1`, `cluster-ludo`, `cluster-immich` still
   build, and the dep graph shows `Deployment → CNP → cilium` for
   packages with workloads and netpol enabled.

### Phase 3 (optional): generalize to calico

1. Create `kix/packages/calico` (helm wrapper).
2. Add `enforcerArg` lookup table in `cluster.nix` keyed off
   `networkPolicyAPI`.
3. Regenerate netpol.nix to emit `NetworkPolicy` (k8s-native) when
   `networkPolicyAPI` is `"calico"` or `"k8s"`, in addition to today's
   `CiliumNetworkPolicy` emission for `"cilium"`. Out of scope for this RFC.

---

## Open questions

- **Platform-provided cilium representation.** Should the RKE2 flavor
  automatically declare an `mkImport` cilium instance (so the resolver
  always finds something) or leave it absent and rely on the `null`
  import-case to degrade gracefully? Leaning toward the former for
  clarity: the flavor says "cilium is here, just not managed by kix."
- **Rebuild identity.** In Phase 2, rebuilt resources have new store
  paths. Any tooling that keys off store-path identity (e.g. the operator's
  resource tracker) needs to handle this. Worth verifying against
  `kix/lib/eval/view.nix` and the CLI's package index builder.
- **Per-Service inverted-ingress attachment.** Phase 2 punts on this and
  attaches cluster-level CNPs to the namespace instead. If users want
  per-Service readiness, it becomes a Phase 2.5 investigation.

## Related work

- RFC 37 — DI-derived network policies (parent design for netpol.nix)
- RFC 79 — Operator readiness edges (consumer of the resource DAG; this
  RFC strengthens the input)
- RFC 48 — System contracts (the `provides` list here is used for the
  self-dep guard; this is a step toward turning `provides` into
  capability-queryable metadata, though that full generalization belongs
  in a separate RFC)
- `kix/lib/compose.nix:expose` — the design pattern the user compared
  this to; differs in that expose is package-opt-in while netpol is
  cluster-level
