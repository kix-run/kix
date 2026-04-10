# 86: Helm DAG Reconstruction — Compiler Guarantees for `fromHelmChart`

**Status:** RFC
**Related:** `40_composite_packages.md`, `38_resource_type_tags.md`, `79_operator_readiness_edges.md`, `37_di_derived_network_policies.md`

---

## Problem

`fromHelmChart` wraps every resource through `mkResource`, so each gains `out.{name, fqdn, selector, identityHash}` and a content-addressed store path. But the *relationships between resources within the chart* are completely lost. All non-root resources are dumped into a flat `requires` list on the root:

```
root (Service or Deployment)
 └── requires: [Deployment, ConfigMap, Secret, ServiceAccount, RBAC, PDB, HPA, ...]
```

This means:
1. **No internal DAG.** Deploy ordering within a Helm chart is "root first, everything else in one wave." A ServiceAccount that a Deployment mounts isn't ordered before the Deployment — they're peers.
2. **No selector linking.** A Service's `spec.selector` points at a Deployment's pod labels, but kix doesn't know they're related. The Service's `out.selector` is auto-derived from `spec.selector.matchLabels`, but there's no edge to the Deployment it selects.
3. **No RBAC linking.** A ClusterRoleBinding references a ServiceAccount, but there's no edge.
4. **No cross-resource validation.** A PodDisruptionBudget's selector might not match any workload. A Service might select pods that don't exist. These are silent bugs.
5. **NetworkPolicy generation is blind.** Doc 37's DI-derived network policies work at the package boundary but can't reason about internal traffic patterns within a Helm chart.

Native kix packages don't have these problems because the author explicitly wires resources:

```nix
service = scope.mkResource {
  spec.selector = deployment.out.selector;  # explicit edge
};
```

The question: can we reconstruct this DAG automatically from the templated Helm output?

---

## Proposal

After `helm template` produces the resource list and before we build the flat `requires` list, run a **link reconstruction pass** that analyzes the resources and infers edges between them. This turns the flat bag of resources into a structured DAG that mirrors what a native kix package author would have written.

### What we can reliably reconstruct

K8s has a handful of well-known linking patterns. All of them are deterministic — they use label selectors or name references, not conventions:

| Link type | Source | Target | How to match |
|---|---|---|---|
| **Service → Workload** | `Service.spec.selector` | `{Deployment,StatefulSet,DaemonSet}.spec.template.metadata.labels` | Label subset match |
| **Ingress → Service** | `Ingress.spec.rules[].http.paths[].backend.service.name` | `Service.metadata.name` | Name equality |
| **HTTPRoute → Service** | `HTTPRoute.spec.rules[].backendRefs[].name` | `Service.metadata.name` | Name equality |
| **RoleBinding → ServiceAccount** | `RoleBinding.subjects[].{kind:"ServiceAccount", name}` | `ServiceAccount.metadata.name` | Name + namespace equality |
| **ClusterRoleBinding → ServiceAccount** | Same as RoleBinding | Same | Name + namespace equality |
| **PDB → Workload** | `PodDisruptionBudget.spec.selector.matchLabels` | Workload pod labels | Label subset match |
| **HPA → Workload** | `HPA.spec.scaleTargetRef.{kind, name}` | Workload name + kind | Kind + name equality |
| **ServiceMonitor → Service** | `ServiceMonitor.spec.selector.matchLabels` | `Service.metadata.labels` | Label subset match |
| **ServiceAccount mount** | `spec.template.spec.serviceAccountName` | `ServiceAccount.metadata.name` | Name equality |
| **ConfigMap/Secret volume** | `spec.template.spec.volumes[].configMap.name` / `secret.secretName` | `ConfigMap`/`Secret.metadata.name` | Name equality |
| **ConfigMap/Secret envFrom** | `spec.template.spec.containers[].envFrom[].{configMapRef,secretRef}.name` | `ConfigMap`/`Secret.metadata.name` | Name equality |

These cover the vast majority of intra-chart relationships. CRD-based links (e.g. `Certificate.spec.issuerRef`) are chart-specific and can be handled by an extension mechanism (see §Open Questions).

### What the reconstructed DAG enables

**1. Deploy ordering within Helm charts.**
Today all non-root Helm resources land in the same wave. With edges, ServiceAccounts and ConfigMaps deploy before the Deployments that reference them. RBAC deploys before the workloads that need it. This matches what `kubectl apply` gets right by accident (server-side ordering) but makes it explicit in the kix plan.

**2. Compile-time validation (warnings).**
- A Service selector that matches zero workload pod templates → warning.
- A PDB selector that matches zero workloads → warning.
- A volume mount referencing a ConfigMap/Secret not in the chart (and not in the cluster) → warning (might be externally managed, so warning not error).
- An HPA targeting a workload that doesn't exist → error.

These catch real Helm chart bugs. Many charts have stale selectors or misconfigured PDBs that only surface at runtime.

**3. Richer `out` for Helm packages.**
Instead of only the root having meaningful `out`, every resource in the chart gets its relationships surfaced. A Helm-wrapped package's Service knows which Deployment it selects. This is useful for `rootOut` authors and for consumers querying `self.*`.

**4. Better network policy generation.**
Doc 37's network policy generation can reason about Service→Workload links within Helm charts rather than treating the whole chart as one opaque blob. If a chart has an internal Redis sidecar Service, the generated CNP can be precise about which pods talk to which.

**5. Smarter composite decomposition.**
Doc 40's composite package migration becomes easier: the reconstructed DAG shows exactly which resources group together, making it clearer where to draw package boundaries.

---

## Design Sketch

### Phase 1: Link extraction (pure Nix)

After `patchResources` and before `wrapHelmResource`, run a linking pass over the raw JSON resources:

```nix
# Conceptual — not final API
linkedResources = linkHelmResources {
  resources = patchedResources;
  # Returns: list of { resource, internalDeps = [ resourceRef ... ]; }
};
```

The linker walks well-known fields and builds a dependency map. It's pure Nix — no IFD, no external tools. The raw JSON resources are already in memory from the `helm template` IFD step.

Each link type is a small function:

```nix
# Service → Workload: selector subset match
linkServiceToWorkload = resources:
  let
    workloads = filter isWorkloadKind resources;
    services = filter (r: r.kind == "Service") resources;
    podLabelsOf = w: w.spec.template.metadata.labels or {};
    selectorOf = svc: svc.spec.selector or {};
    isSubset = selector: labels:
      builtins.all (k: labels.${k} or null == selector.${k}) (builtins.attrNames selector);
  in
    map (svc: {
      from = svc;
      to = filter (w: isSubset (selectorOf svc) (podLabelsOf w)) workloads;
      type = "selects";
    }) services;
```

### Phase 2: Edge injection into `wrapHelmResource`

The extracted links become `requires` edges on the wrapped resources:

```nix
# Instead of: all non-root → root
# Now: each resource → its actual dependencies

wrappedWithEdges = map (linked:
  let
    wrapped = wrapHelmResource { inherit scope; resource = linked.resource; };
    depResources = map (ref: wrappedByIdentity.${identityOf ref}) linked.internalDeps;
  in
    wrapped // { requires = wrapped.requires ++ depResources; }
) linkedResources;
```

The root's `requires` becomes only resources that have no other parent in the DAG (true top-level siblings), rather than everything.

### Phase 3: Compile-time warnings

Orphan detection runs after linking:

```nix
# Services whose selector matches zero workloads
orphanServices = filter (link: link.to == [] && link.type == "selects") allLinks;
# → emit diagnostic via doc 80's structured diagnostics
```

This integrates with the structured diagnostics system (doc 80) — warnings are surfaced in `kix diff` and the CLI, not buried in eval output.

---

## Motivation

### Why not just go native? (Addressing doc 40)

Doc 40 argues for decomposing Helm bundles into native kix packages. That's the right long-term direction for *mega-charts* like kube-prometheus-stack. But:

1. **Most Helm charts shouldn't be decomposed.** A chart for PostgreSQL, Redis, or Grafana is a single logical unit. Decomposing it into 8 native packages gains nothing — it's one upstream project with one release cycle. `fromHelmChart` is the right abstraction for these.

2. **Migration effort is enormous.** There are ~40 Helm-wrapped packages in kixpkgs today. Migrating each to native takes hours of work. DAG reconstruction gives 80% of the compiler guarantees for 0% migration effort.

3. **Helm charts are an acquisition funnel.** New users start with `fromHelmChart` because it's familiar. Making that path safer reduces the cost of adoption. "Import your Helm chart and get compile-time validation for free" is a strong pitch.

4. **The two approaches compose.** Reconstructed DAGs make migration *easier* because they reveal the internal structure. A developer looking at the reconstructed DAG of kube-prometheus-stack can see exactly where to draw the package boundaries for doc 40's composite decomposition.

### Why this is worth the complexity

The linking rules are simple and well-defined — K8s has a small, stable set of reference patterns. The implementation is ~200 lines of pure Nix (label subset matching, name lookups). It runs once at eval time alongside the existing `helm template` IFD. The cost is low; the payoff is:

- Fewer silent Helm chart bugs reaching clusters
- Better deploy ordering for free
- Precise network policies for Helm packages
- A visible internal DAG that aids migration decisions

---

## Alternatives Considered

### A. Status quo + better `rootOut`

Keep the flat structure, require package authors to manually reconstruct important links via `rootOut`. This is what we do today for cilium (`cnpCrdRef`) and reflector (`reflectSecret`).

**Rejected because:** This only helps for outputs that cross the package boundary. Internal ordering and validation remain broken. Every Helm package author must rediscover and re-wire links that are already declared in the Helm template output.

### B. Rust oracle for Helm parsing

Move the DAG reconstruction into the Rust oracle (doc 36) rather than pure Nix. The oracle would parse `helm template` output and return a structured DAG.

**Deferred, not rejected.** This makes sense if the linking logic grows complex (e.g., CRD-specific link types that need schema awareness). For the well-known K8s link types, pure Nix is sufficient and avoids adding Rust oracle coupling. If we later need schema-aware CRD linking, the oracle is the right place.

### C. Full static analysis of Helm templates (pre-render)

Analyze the Go templates before rendering to understand conditional resource generation and variable-dependent selectors.

**Rejected:** Massively complex, fragile, and unnecessary. The rendered output already has all the information we need — selectors are concrete values, not template expressions.

---

## Open Questions

### 1. CRD-specific link types

The well-known K8s links cover core resources. But charts emit CRs with custom reference patterns (e.g., `Certificate.spec.issuerRef`, `Prometheus.spec.serviceMonitorSelector`). Should we:

- (a) Only handle core K8s link types (Services, RBAC, volumes, etc.) and ignore CRs
- (b) Allow `fromHelmChart` callers to declare custom link extractors
- (c) Build a registry of known CRD link patterns (cert-manager, prometheus-operator, etc.)

Leaning toward (a) for the first iteration, with (b) as an escape hatch. (c) is maintenance burden for diminishing returns.

### 2. Cross-namespace references within a chart

Some charts create resources in multiple namespaces (e.g., kube-system DaemonSets alongside the main namespace). The linker must be namespace-aware when matching names. `wrapHelmResource` already handles foreign namespaces via `scope.forNamespace` — the linker needs to respect the same logic.

### 3. Warning vs. error threshold

A Service with no matching workload might be intentional (the workload is managed outside the chart). Default to warnings, but allow `fromHelmChart` callers to escalate specific checks to errors?

### 4. Performance impact

The linking pass is O(n*m) for label matching (n services * m workloads). For typical Helm charts (10-50 resources, 1-5 workloads), this is negligible. For mega-charts (kube-prometheus-stack: ~200 resources), it might matter. Profile before optimizing.

### 5. Interaction with `patchResources`

`patchResources` runs before linking. If a user patches a selector, the linker sees the patched version. This is correct — the patched output is what gets deployed. But it means the linker validates the *final* resources, not the chart's original output. Document this clearly.
