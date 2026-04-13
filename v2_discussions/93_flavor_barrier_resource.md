# 93: Flavor Barrier Resource

**Status:** Design
**Related:** `81_deploy_as_lifecycle_engine.md`, `92_declarative_network_policy_intents.md`

## Problem

Flavors define platform instances (`kind-system-netpol`, `platform-dns`, `platform-storage`) that must be Ready before user workloads deploy. Today these instances have no ordering priority — wave placement is purely derived from store-path context and explicit `requires` edges. If no user package happens to reference a flavor resource's `out`, the flavor resource lands wherever Kahn's algorithm puts it — potentially in parallel with workloads that need it.

Concrete driver: `kind-system-netpol` emits CNPs for kind's system pods (CoreDNS, local-path-provisioner). When Cilium's `always` enforcement mode is on, those CNPs must be applied *before* user pods try to reach CoreDNS. Without an ordering guarantee, user Deployments race the system netpol and pods fail DNS resolution on first deploy.

## Design: Barrier resource in the DAG

The flavor emits a synthetic **`PlatformBarrier`** resource. Every non-flavor PackageInstance gets an automatic `requires` edge to it. The barrier itself depends on all flavor-defined instances that are active.

```
                  ┌──────────────┐
                  │ PlatformBarrier │
                  └──────┬───────┘
           ┌─────────────┼─────────────┐
           ▼             ▼             ▼
    kind-system-   platform-dns   platform-storage
       netpol       (import)        (import)
           ▲             ▲             ▲
           │             │             │
    ┌──────┴─────────────┴─────────────┴──────┐
    │  every non-barrier PackageInstance       │
    │  (cilium, my-app, ingress-nginx, ...)   │
    └─────────────────────────────────────────┘
```

Wait — the arrows are confusing. Let's use the kix convention where edges point from dependent → dependency (outgoing = "I depend on"):

```
Activation
  └→ PI(my-app)
       └→ PlatformBarrier          ← automatic requires edge
            ├→ PI(kind-system-netpol)
            ├→ PI(platform-dns)      (only if activated)
            └→ PI(platform-storage)  (only if activated)
  └→ PI(cilium)
       └→ PlatformBarrier          ← same edge
  └→ PI(kind-system-netpol)
       (NO edge to PlatformBarrier — it's a flavor instance)
```

The barrier is a single convergence point: flavor instances deploy in early waves (wave 0–N based on their own internal dependencies), the barrier lands in wave N+1, and everything else follows from N+2 onward.

## Mechanism

### Nix side

**Where the barrier is created:** In `cluster.nix`, after the fixpoint is built and active instances are determined, but before `allResources` is assembled. It uses `mkResource` like any other kix resource.

**How flavor instances are identified:** An instance is "flavor-defined" if it was declared by a flavor module. Two options:

1. **Tag on the instance:** Flavors set `infrastructure = true` on their instances. The barrier collects all active instances with this tag.
2. **Automatic detection:** Track which module declared each instance via the module system. Too magical — breaks when a cluster author overrides a flavor instance.

Option 1 is better. It's explicit, composable (non-flavor packages like cert-manager can also opt in), and trivial to implement.

```nix
# In modules.nix — new instance option
infrastructure = lib.mkOption {
  type = lib.types.bool;
  default = false;
  description = ''
    Infrastructure instance — must be Ready before non-infrastructure
    instances deploy. Flavor modules set this for platform-critical
    services (CNI netpols, storage provisioners, etc.). The cluster
    builder synthesizes a PlatformBarrier resource that gates all
    non-infrastructure PackageInstances on all active infrastructure
    PackageInstances.
  '';
};
```

```nix
# In kind.nix
instances.kube-system.kind-system-netpol = {
  package = import ../../packages/kind-system-netpol/default.nix;
  infrastructure = true;
};
```

**How the barrier resource is built:** In `cluster.nix`, after the fixpoint:

```nix
# Collect active infrastructure PIs
infraPIs = builtins.filter (inst:
  let instCfg = mergedInstances.${inst._meta.namespaceName}.${inst._meta.instanceName};
  in instCfg.infrastructure or false
) allInstancesList;

# Build barrier resource (only if there are infra instances)
platformBarrier = if infraPIs == [] then null else
  k8s.mkResource {
    apiVersion = "kix.dev/v1alpha1";
    kind = "PlatformBarrier";
    name = "platform";
    namespace = k8s.clusterScoped;
    # The barrier depends on every infra PI → Kahn's places it after them
    requires = map (inst: inst._packageInstance) infraPIs;
  };
```

**How the automatic edge is injected:** The tricky part. Options:

**Option A — Stamp at PI creation time.** Pass the barrier resource into `evaluateInstance` and have `mkPackageInstance` add it to `packageRequires` for non-infrastructure instances. Problem: the barrier depends on infra PIs, which are produced by the fixpoint, so the barrier can't exist before the fixpoint runs. Circular.

**Option B — Post-fixpoint annotation.** Build the barrier after the fixpoint. Walk all non-infra PIs and add the barrier's identity hash to their `kix.dev/depends-on` annotation. This is a post-processing rewrite of already-built resources. Ugly but avoids circularity.

**Option C — CLI-side injection.** The Nix side emits metadata (list of infra PI identity hashes + the barrier's hash). The CLI injects edges during graph construction (Phase 2 in `graph.rs`). Clean separation: Nix declares intent, CLI enforces ordering.

**Option D — Barrier as a fixpoint participant.** Make the barrier a real instance (synthetic package) that participates in the fixpoint. Its `out` is referenced by all non-infra instances via a mechanism similar to `networkPolicyEnforcer`. Every non-infra PI gets `requires = [ platformBarrier ]`.

### Recommendation: Option D (fixpoint participant)

This is the most natural fit for the existing architecture. The pattern already exists for `networkPolicyEnforcer` — a special instance discovered by convention and threaded into every scope.

**Implementation sketch:**

1. Add a `PlatformBarrier` synthetic package (similar to how kixCRDs are synthetic resources).
2. During `clusterInstances` fixpoint, collect infra PI refs.
3. The barrier's `_packageInstance` depends on all infra PIs via `requires`.
4. Every non-infra `evaluateInstance` call receives `platformBarrier` in its args (like `networkPolicyEnforcer`).
5. `mkPackageInstance` for non-infra instances adds the barrier to `packageRequires`.

The circularity concern: the barrier depends on infra PIs, and non-infra PIs depend on the barrier. But infra PIs do NOT depend on the barrier, so the cycle breaks cleanly. The fixpoint's laziness handles this — the barrier's store path is only forced when non-infra PIs are forced, and by that time the infra PIs are already computed.

### What about `mkImport` optional instances?

Platform imports (`platform-dns`, `platform-storage`) are `optional = true` and produce no K8s resources (`_isImport = true`). They have no `_packageInstance` because imports don't generate PIs.

Should they be behind the barrier? **No.** Imports are references to pre-existing cluster services. They're already running. The barrier is for *kix-managed* infrastructure that needs to deploy before user workloads.

Only non-import infrastructure instances (like `kind-system-netpol`, or a kix-managed Cilium, or cert-manager) should be barrier participants.

## Avoiding the "one slow resource blocks everything" problem

The single-barrier design means all non-infra resources wait for ALL infra resources. If one infra instance is slow (e.g., Cilium operator taking 2 minutes to become Ready), everything else waits.

Is this actually a problem? For infrastructure, **probably not:**

- Infrastructure instances are foundational by definition. If Cilium isn't Ready, deploying workloads that depend on CNP enforcement is wrong anyway.
- The alternative (fine-grained per-infra-instance edges) reintroduces the complexity we're trying to avoid. Each user package would need to know which specific infra it depends on.
- In practice, infrastructure instances are small and fast (CRDs, CNPs, namespace-level config). The slow ones (Cilium, cert-manager) are ones everything genuinely depends on.

If this becomes a real bottleneck later, the escape hatch is straightforward: split `infrastructure = true` into named barrier groups (`infrastructure = "network"`, `infrastructure = "storage"`), each producing a separate barrier resource. Non-infra instances opt into which barriers they need. But this is YAGNI — start with one barrier.

## Edge case: infra instance depending on a user instance

This would be a design bug. An infrastructure instance that depends on a user instance creates a cycle: user → barrier → infra → user. The fixpoint would stack-overflow or the CLI would detect a cycle.

**Guard:** Add a scorecard rule or assertion: "infrastructure instances must not have DI dependencies on non-infrastructure instances." This is a compile-time check, not a runtime one.

## CLI-side changes

Minimal. The barrier is a regular resource in the DAG with `kix.dev/depends-on` annotations. The existing Kahn's algorithm places it correctly without any special-casing. The CLI doesn't need to know about the barrier concept — it's just another resource with edges.

The one change: the `PlatformBarrier` kind needs a readiness definition. Since it has no spec (it's a pure ordering construct), readiness = "exists on the cluster" (same as Namespace resources today). Or: skip applying it entirely and treat it as a DAG-only phantom — the CLI could filter out `PlatformBarrier` from the apply set while keeping it in the graph for wave computation.

**Phantom resource approach:** The barrier resource is never `kubectl apply`'d. It exists only in the Nix store DAG and the CLI's in-memory graph. The CLI strips it before applying each wave but uses it for wave computation. This is cleaner — no CRD needed, no cluster-side artifact.

## Single barrier vs. per-namespace barriers

Single cluster-scoped barrier. Reasons:

- Infrastructure is inherently cross-namespace (Cilium, cert-manager, storage provisioners operate cluster-wide).
- Per-namespace barriers would require each namespace to know which infra it needs — back to fine-grained wiring.
- A single barrier is simple to reason about: "infra first, then everything else."

## Summary of changes

| Layer | Change |
|-------|--------|
| `modules.nix` | Add `infrastructure` bool option to instance submodule |
| `kind.nix` (and other flavors) | Set `infrastructure = true` on managed instances |
| `cluster.nix` | Build `PlatformBarrier` phantom resource, thread into non-infra instance eval |
| `eval/instance.nix` | Accept `platformBarrier` arg, add to `packageRequires` for non-infra instances |
| `k8s.nix` | (Optional) Add `mkPlatformBarrier` helper alongside `mkActivation` |
| CLI `graph.rs` | (Optional) Filter phantom resources from apply set |
| CLI `waves.rs` | No changes — Kahn's handles it |

## Open questions

1. **Naming:** `infrastructure` or `platform`? Both are overloaded terms. `infrastructure` is clearer ("this must exist before apps run"). `platform` aligns with the existing `platform-dns`/`platform-storage` naming but those are imports, not infra.

2. **Should Cilium itself be infrastructure?** When a cluster declares Cilium as a kix-managed instance, should the Cilium package auto-set `infrastructure = true` via `meta.infrastructure = true`? Or should this always be a cluster-level decision? Leaning toward: packages can *default* it via meta, cluster authors can override.

3. **Interaction with Phase 2b cross-package edge collapse.** The disabled code in `graph.rs` (lines 96-163) tried to collapse cross-package edges onto target PIs. If re-enabled, would it conflict with the barrier? No — the barrier is a separate mechanism (structural ordering, not edge rewriting). But both solve related problems. Should the barrier make Phase 2b unnecessary? Probably not — Phase 2b is about "wait for the whole target package," the barrier is about "wait for all infra."

4. **Phantom resource or real CRD?** Leaning phantom (no cluster-side artifact, pure DAG construct). But a real CRD would let `kix status` show "platform ready: yes/no" which is nice for debugging.
