# 96: Network Policy Auto-Generation Blindspots

**Status:** Superseded by archive/130 (implemented via PR #31 — ConfigMap-indirection and import-ref blindspots closed by fact conduction; operator-operand blindspot partially closed by factBehavior terminate).
**Related:** `92_declarative_network_policy_intents.md`, `94_dns_dependency_chain_step2.md`, `archive/83_netpol*`, `archive/85_netpol_simplification.md`

## Problem statement

kix's netpol auto-derivation relies on a single mechanism: **Nix store-path context analysis**. When a workload's JSON is built from Nix expressions that interpolate a Service's store path, `extractServiceEdgesFromJson` discovers the edge and emits the correct egress/ingress CNPs. This works beautifully for the happy path — a kix-native package with a Deployment that references another package's Service via `dep.out.fqdn` in its pod spec.

But the ludo cluster buildout exposed three classes of workloads where this mechanism is structurally blind. Each requires manual escape hatches today, and the escape hatches are non-obvious, poorly documented, and easy to forget.

---

## Blindspot 1: Helm charts — opaque value rendering

**The mechanism:** Helm charts are rendered by `helm template` at eval time. The rendered YAML is then parsed back into Nix and split into individual resources. kix can inject values into the chart (via the `values` parameter to `importChart`), and those values *do* carry Nix store-path context — but only in the values attrset itself, not in the rendered output.

**Why it breaks:** `helm template` is an opaque string transformation. When kix passes `values.config.clients[0].url = "http://${loki.out.fqdn}/loki/api/v1/push"`, the Nix store-path context of `loki.out.fqdn` exists in the values JSON. But the rendered Deployment manifest is a fresh string produced by Go's template engine — it no longer carries the Nix store-path references. `extractServiceEdgesFromJson` sees the rendered Deployment and finds no store-path context.

**Current escape hatch:** `importChart` accepts a `networkDeps` parameter. Package authors manually list the dependencies whose store-path context should be injected:

```nix
# kix/packages/promtail/default.nix
resources = scope.helm.importChart {
  inherit chart scope;
  values = lib.recursiveUpdate defaultValues lokiValues;
  releaseName = "promtail";
  networkDeps = [ loki.out.fqdn ];  # <-- manual!
};
```

Under the hood, `networkDeps` values are stamped into a `_helmNetworkDeps` annotation on each Helm-rendered workload, making their store-path context visible to `extractServiceEdgesFromJson`.

**Why the escape hatch is painful:**
- Package authors must know that Helm breaks auto-detection (non-obvious).
- They must manually identify *which* DI deps are network targets (error-prone).
- Forgetting a dep produces no build error — you only discover it at runtime when default-deny blocks traffic.
- The `networkDeps` parameter is Helm-specific; ConfigMap-based references (blindspot 3) have no equivalent.

**Scope:** Every Helm-wrapped package that communicates with another kix-managed service. In ludo: promtail → loki-gateway.

---

## Blindspot 2: Operator-managed workloads — invisible pods

**The mechanism:** kix's `buildWorkloadCnps` runs inside `scope.mkWorkload` (which backs `mkDeployment`, `mkStatefulSet`, etc.). It intercepts the workload *before* the resource is built, extracts edges, and emits CNPs with the correct `endpointSelector.matchLabels` matching the workload's pod selector.

**Why it breaks:** Operators like StackGres create their own StatefulSets, Services, Jobs, and CronJobs at runtime. These workloads:
- Are never created via `scope.mkStatefulSet` — so `buildWorkloadCnps` never runs for them.
- Use operator-specific labels (e.g., `app=StackGresCluster`, `stackgres.io/cluster-name=<name>`) that kix doesn't know about.
- May have complex internal communication patterns (patroni HA, replication, extension downloads) that aren't discoverable from the CRD spec.

**Current escape hatch:** Package authors hand-roll netpol resources using the enforcer API directly:

```nix
# kix/packages/stackgres-cluster/default.nix (~50 lines of manual netpol)
sgClusterEgress =
  if scope.networkPolicyEnforcer == null then null
  else scope.networkPolicyEnforcer.netpol.mkPolicy {
    mkResource = scope.mkResource;
    extraArgs = {
      name = "${name}-sgcluster-egress";
      spec = {
        endpointSelector.matchLabels = sgPodSelector;
        egress = [
          scope.networkPolicyEnforcer.netpol.dnsEgressRule
          scope.networkPolicyEnforcer.netpol.apiServerEgressRule
          { toEndpoints = [ { matchLabels = sgPodSelector; } ]; }
          (scope.networkPolicyEnforcer.netpol.mkExternalEgressRule { })
        ];
      };
      extraDeps = [ ];
    };
  };
```

**Why the escape hatch is painful:**
- Package authors must understand Cilium's selector model, entity names, and rule structure.
- They must manually enumerate every communication pattern the operator's pods need (DNS, apiserver, self-communication, external registries, consumer ingress).
- The ingress side is especially bad: because kix doesn't know about operator-managed Services, it can't emit caller-ingress CNPs for *consumers* of those services either. StackGres works around this with a blanket `fromEntities = ["cluster"]` on port 5432 — way over-permissioned compared to what auto-derivation would produce.
- Each operator package independently rediscovers and reimplements the same pattern.

**Scope:** Every operator-pattern package. In ludo: stackgres-cluster (StackGres operator creates StatefulSets). Also affects cert-manager (creates Jobs for certificate issuance), any future operator-managed workload.

---

## Blindspot 3: Transitive service references — ConfigMaps and indirection

**The mechanism:** `extractServiceEdgesFromJson` analyzes the store-path context of the workload's input JSON (the attrs passed to `mkWorkload`). For a reference to be detected, the Service's store path must appear in the *workload's own* string context.

**Why it breaks:** When a service FQDN is referenced in a ConfigMap (or Secret) that's *mounted* by the workload, the store-path context flows like this:

```
loki.out.fqdn  →  ConfigMap data  →  ConfigMap resource  →  workload's volume mount
                    ↑                                         ↑
                    context is HERE                            context is NOT here
```

The ConfigMap resource carries the store-path context of `loki.out.fqdn` in its data field. But the workload's pod spec only references the ConfigMap by *name* (a plain string like `"promtail-config"`). The workload's input JSON has no transitive store-path reference to the Services embedded in the ConfigMap.

This is the same fundamental issue as blindspot 1 (Helm), but for a different reason: Helm loses context through Go template rendering; ConfigMap indirection loses context through the Kubernetes resource boundary.

**Current escape hatch:** Same as Helm — `networkDeps` on `importChart`, or for native packages there is no built-in mechanism at all. You'd have to manually ensure the service ref appears in the workload's attrs (e.g., add it to `extraDeps` or use an annotation).

**Why the escape hatch is painful:**
- Same issues as blindspot 1, plus: for native packages (non-Helm), there isn't even a `networkDeps` parameter. You'd need to either pollute the workload spec with unused references or hand-roll CNPs like blindspot 2.
- The indirection pattern is *extremely* common: almost every app references its database URL, cache endpoint, or message broker through a ConfigMap or Secret, not inline in the pod spec.

**Scope:** Any package where the service reference flows through a ConfigMap, Secret, or any intermediate resource rather than appearing directly in the workload's pod spec. In ludo: promtail (loki URL in Helm-rendered ConfigMap — combines blindspot 1 and 3).

---

## Common thread

All three blindspots share the same root cause: **store-path context analysis can only see edges that are lexically present in the workload's input attrs**. Any indirection — Helm rendering, operator reconciliation, ConfigMap mounting — breaks the chain.

The current escape hatches are:
1. `networkDeps` on `importChart` (Helm-specific, manual)
2. Hand-rolled `scope.networkPolicyEnforcer.netpol.mkPolicy` calls (operator-managed, verbose, enforcer-coupled)
3. Nothing built-in (ConfigMap indirection in native packages)

None of these are discoverable, none produce build-time errors when forgotten, and each requires deep knowledge of kix internals.

## Overlap with existing docs

- **Doc 92 (declarative intents)** addresses the *declaration* surface — how flavors/packages express connectivity needs without constructing enforcer-specific CRs. It would improve blindspot 2 (operator-managed workloads could declare intents instead of hand-rolling Cilium rules) but doesn't address the *detection* gap in blindspots 1 and 3.
- **Doc 94 (DNS dependency chain)** addresses the DNS dep injection side of the same detection mechanism. Its step 1 rework made DNS deps per-workload (sharing `extractServiceEdgesFromJson`), which means DNS deps have the same blindspots as netpol.
- **Doc 95 (build-time validation)** could catch *some* of these at eval time (e.g., "this workload has no egress rules but references services in its ConfigMap"), but only if we have a way to detect the reference in the first place.

## Design space (to be explored)

Three possible directions, not mutually exclusive:

### A. Improve detection — chase context through indirection

Teach `extractServiceEdgesFromJson` (or a new analysis pass) to follow store-path context transitively: if a workload mounts a ConfigMap, and that ConfigMap's data carries a Service's store-path context, attribute the edge to the workload.

**Pro:** Fully automatic, no package-author burden. Fixes blindspot 3 and partially fixes 1 (Helm values carry context even if rendered output doesn't).
**Con:** Requires a post-fixpoint pass (workloads reference ConfigMaps by name, ConfigMaps are sibling resources). More complex analysis. Doesn't help blindspot 2 at all (operator pods don't exist at eval time).

### B. Improve declaration — make escape hatches first-class

Generalize `networkDeps` beyond Helm into a universal `scope.mkWorkload` parameter. Combine with doc 92's intent system so operator packages can declare connectivity patterns declaratively.

**Pro:** Works for all three blindspots. Simpler implementation. Intents from doc 92 handle the operator case cleanly.
**Con:** Still requires package authors to manually declare edges. Still no build-time error if they forget.

### C. Improve validation — catch missing edges at build time

Build-time analysis that cross-references: (a) ConfigMaps/Secrets whose data references Services, with (b) workloads that mount those ConfigMaps/Secrets, and checks whether the workload has corresponding netpol rules. Emit warnings for uncovered edges.

**Pro:** Catches forgotten edges regardless of how they got there. Works as a safety net for both A and B.
**Con:** Can only warn, not fix. May have false positives (not every string that looks like a service FQDN *is* a network dependency).

---

## Next steps

Discuss which direction(s) to pursue and in what order. The low-hanging fruit is probably B (generalize escape hatches + doc 92 intents), with C as a safety net. A is the most ambitious but the most rewarding long-term.
