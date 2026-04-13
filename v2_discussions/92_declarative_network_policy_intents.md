# 92: Declarative Network Policy Intents

**Status:** RFC
**Related:** `archive/37_di_derived_network_policies.md`, `archive/82_cilium_package_and_netpol_di_wiring.md`, `archive/83_netpol_via_crdref_and_scope_interception.md`, `archive/85_netpol_simplification.md`

## Problem

kix has two policy-generation paths and neither covers the full surface:

1. **Auto-derived** (`netpol.nix`): DI graph → per-workload CNPs. Works beautifully for kix-managed workloads. Routed through `cnpCrdRef.out.cr` so the enforcer dependency is wired.

2. **Hand-rolled**: Packages like `kind-system-netpol` and `network-policies` construct Cilium CRs directly — stamping `apiVersion: cilium.io/v2`, `kind: CiliumClusterwideNetworkPolicy`, and manually wiring `requires`. This bypasses the CRD-ref machinery and hard-codes the enforcer.

The hand-rolled path exists because three use cases fall outside auto-derivation:

- **Platform pods not managed by kix** (CoreDNS, local-path-provisioner in kind). No kix package → no DI edges → no auto-derived policies. The kind flavor works around this by importing `kind-system-netpol`, a whole package whose only job is hand-rolling CNPs.
- **Cluster-wide baseline policies** (global DNS, global internet, Kubernetes API access). These apply to all pods regardless of DI edges. The `network-policies` package provides them via a `mkCiliumPolicy` helper that calls `scope.mkClusterResource` with raw apiVersion/kind — no CRD-ref routing at all.
- **Flavor-specific connectivity** that varies by platform (kind needs CoreDNS policies, GKE doesn't). Currently encoded as conditional package imports, not declarative.

All three cases share the same root issue: **there is no way to declare "this pod needs this connectivity" without constructing an enforcer-specific CR yourself.**

Doc 85 explicitly closed this: "Cilium-only is fine. No pluggable backend, no abstraction layer." That was the right call for the auto-derived path (which runs inside `netpol.nix` and is tightly coupled to Cilium's selector model). But for the declaration surface — where flavors and packages say *what* connectivity they need — enforcer coupling is unnecessary and harmful:

- Flavors shouldn't know whether the cluster uses Cilium or Calico to say "CoreDNS needs DNS ingress."
- Baseline policies shouldn't hand-roll CRs to say "all pods can reach DNS."
- Adding a CCNP shouldn't require knowing `ciliumclusterwidenetworkpolicies` is the plural form.

## Design

### Layer 1: Policy intents (enforcer-agnostic)

A **policy intent** declares connectivity requirements without referencing any specific enforcer. It uses kix's own vocabulary for common patterns:

```nix
# Namespaced intent — targets pods in a specific namespace
{
  name = "coredns-egress";
  scope = "namespaced";              # default
  namespace = "kube-system";         # required for platform pods
  podSelector = { "k8s-app" = "kube-dns"; };
  egress = [
    { to = "apiserver"; }
    { to = "world"; ports = [ { port = 53; protocol = "UDP"; } { port = 53; protocol = "TCP"; } ]; }
  ];
}

# Cluster-wide intent — targets pods across namespaces
{
  name = "local-path-provisioner-egress";
  scope = "clusterwide";
  podSelector = {
    "app.kubernetes.io/name" = "local-path-provisioner";
  };
  targetNamespace = "local-path-storage";   # which ns the pods live in
  egress = [
    { to = "apiserver"; }
    { to = "dns"; }                         # shorthand for the cluster DNS service
  ];
}
```

**Intent rule vocabulary:**

| Field | Maps to (Cilium) | Maps to (K8s NetworkPolicy) |
|---|---|---|
| `to = "apiserver"` | `toEntities = ["kube-apiserver"]` | Not expressible (skip) |
| `to = "world"` | `toEntities = ["world"]` | `to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]` |
| `to = "dns"` | `toEndpoints` matching cluster DNS + port 53 | `to` matching DNS + port 53 |
| `from = "all-pods"` | `fromEndpoints = [{}]` | `from: [{ podSelector: {} }]` |
| `from = "world"` | `fromEntities = ["world"]` | `from: [{ ipBlock: { cidr: 0.0.0.0/0 } }]` |
| `to/from = { selector = {...}; namespace = "..."; }` | `toEndpoints`/`fromEndpoints` with matchLabels | `to`/`from` with podSelector + namespaceSelector |
| `ports = [...]` | `toPorts` | `ports` |

This vocabulary covers every rule currently hand-rolled in `kind-system-netpol` and `network-policies`. For enforcer-specific features not in this table (L7 rules, FQDN policies, CIDR sets), use a passthrough:

```nix
{ raw = { /* native Cilium/Calico spec fragment */ }; }
```

### Layer 2: Declaration sites

Policy intents can be declared in three places:

**A. Flavor-level** — platform connectivity for non-kix-managed pods:

```nix
# kix/lib/flavors/kind.nix
{
  cluster.networkPolicy.platformIntents = {
    coredns-egress = {
      namespace = "kube-system";
      podSelector = { "k8s-app" = "kube-dns"; };
      egress = [
        { to = "apiserver"; }
        { to = "world"; ports = [ { port = 53; protocol = "UDP"; } { port = 53; protocol = "TCP"; } { port = 443; protocol = "TCP"; } ]; }
      ];
    };
    coredns-ingress = {
      namespace = "kube-system";
      podSelector = { "k8s-app" = "kube-dns"; };
      ingress = [
        { from = "all-pods"; ports = [ { port = 53; protocol = "UDP"; } { port = 53; protocol = "TCP"; } ]; }
      ];
    };
    local-path-provisioner-egress = {
      scope = "clusterwide";
      targetNamespace = "local-path-storage";
      podSelector = { "app.kubernetes.io/name" = "local-path-provisioner"; };
      egress = [
        { to = "apiserver"; }
        { to = "dns"; }
      ];
    };
  };
}
```

This **replaces the entire `kind-system-netpol` package**. The flavor declares intents; the enforcer materializes them. No package import, no hand-rolled CRs.

**B. Cluster-level** — baseline policies that apply everywhere:

```nix
# Cluster definition or a "network-policies" package's config
cluster.networkPolicy.baselineIntents = {
  global-dns = {
    scope = "clusterwide";
    egress = [ { to = "dns"; } ];
  };
  global-internet-access = {
    scope = "clusterwide";
    egress = [ { to = "world"; } ];
  };
  kubernetes-api-access = {
    scope = "clusterwide";
    egress = [ { to = "apiserver"; } ];
  };
};
```

This replaces `network-policies`'s `mkCiliumPolicy` helpers. The `network-policies` package becomes a thin config layer over these intents rather than a CR factory.

**C. Package-level** — connectivity that a package needs but can't express via DI:

```nix
# In a package's meta
meta.network.intents = {
  # "My pods need to reach an external API"
  external-api-egress = {
    egress = [
      { to = "world"; ports = [ { port = 443; protocol = "TCP"; } ]; }
    ];
  };
};
```

This replaces the dead `meta.network.{extraEgress, extraIngress, allowExternalEgress}` surface from doc 85. Unlike the old surface (which was threaded as raw Cilium rules through `buildWorkloadCnps`), intents are enforcer-agnostic and materialized by the enforcer.

### Layer 3: Enforcer materialization

The enforcer (cilium) provides a **materializer** — a function that turns intents into CRs routed through its CRD refs:

```nix
# In cilium's build function or a new enforcer API
materializeIntent = { scope, intent }:
  let
    # Translate abstract rules to Cilium-native spec
    spec = translateToCilium intent;
  in
  if (intent.scope or "namespaced") == "clusterwide" then
    ccnpCrdRef.out.mkCR scope { name = intent.name; inherit spec; }
  else
    cnpCrdRef.out.mkCR scope { name = intent.name; inherit spec; };
```

The `translateToCilium` function maps the intent vocabulary to Cilium's native fields. This is the **only** place that knows about `toEntities`, `fromEndpoints`, `CiliumClusterwideNetworkPolicy`, etc.

**Where does materialization happen?** In `cluster.nix`, after the enforcer is resolved:

```
cluster.nix
  ├── resolve enforcer (existing)
  ├── collect intents from:
  │   ├── flavor.networkPolicy.platformIntents
  │   ├── cluster.networkPolicy.baselineIntents
  │   └── per-instance meta.network.intents
  ├── enforcer.materializeIntent(each intent)
  │   └── routes through cnpCrdRef / ccnpCrdRef
  └── inject materialized resources into the resource graph
```

### What this kills

| Current | After |
|---|---|
| `kind-system-netpol` package (62 lines of hand-rolled Cilium CRs) | ~15 lines of intent declarations in `kind.nix` |
| `network-policies`'s `mkCiliumPolicy` helper | Intents on `cluster.networkPolicy.baselineIntents` |
| `scope.mkClusterResource { apiVersion = "cilium.io/v2"; kind = "CiliumClusterwideNetworkPolicy"; ... }` in packages | `scope = "clusterwide"` on an intent |
| Dead `meta.network.{extraEgress, extraIngress, ...}` (doc 85 said delete) | `meta.network.intents` — actually useful this time |
| `cnpCrdRef` as the only CRD ref | Both `cnpCrdRef` and `ccnpCrdRef` (already added) |

### What this does NOT change

- **Auto-derived policies** (`netpol.nix` / `buildWorkloadCnps`). These stay Cilium-coupled inside `netpol.nix` — they read store-path context and emit CNPs through `cnpCrdRef.out.cr`. The intent layer is for *declared* connectivity, not *derived* connectivity.
- **Default-deny generation** (`generateDefaultDeny`). Stays as-is.
- **CRD-ref routing** (`buildCnp` → `cnpCrdRef.out.cr`). The intent materializer uses this, but it's an existing mechanism.

## Open questions

1. **Should `network-policies` become pure intents?** Currently it's a package with options (`clusterwidePolicies.globalDns`, tenant isolation, etc.). Converting to intents means its config surface moves to `cluster.networkPolicy.baselineIntents`. The tenant isolation and per-namespace internal-system-traffic policies are more complex — do they fit the intent model or stay as package logic?

2. **Intent validation.** Who validates that intent rules are expressible by the resolved enforcer? If someone uses `to = "apiserver"` and the enforcer is vanilla K8s NetworkPolicy (which can't express entity-based rules), do we warn or error?

3. **`raw` passthrough scope.** How much of the enforcer's native API should be passthrough-able? If we allow arbitrary Cilium spec fragments in `raw`, we've reintroduced enforcer coupling at the declaration site. Maybe `raw` should be on the cluster/enforcer config, not on intents.

4. **Package intents and the workload selector.** When a package declares `meta.network.intents`, the `podSelector` should default to the package's own workload selector. How do we wire that — does the materializer read `self.out.selector`?

5. **Ordering.** Platform intents (flavor) need to be applied before user workloads come up. Are they injected as dependencies of the namespace resource, or of the enforcer itself?

## Recommended sequencing

1. **Ship `ccnpCrdRef` on cilium** (already done in this session). Mechanical fix, no design needed.
2. **Add `platformIntents` to flavor config + materializer.** Proves the intent→CR pipeline on the simplest case (kind). Deletes `kind-system-netpol`.
3. **Add `baselineIntents` to cluster config.** Migrates `network-policies`'s cluster-wide baselines. The package shrinks to tenant/namespace logic.
4. **Add `meta.network.intents` for packages.** Replaces the dead `meta.network.*` surface with something that has actual consumers.
5. **Extract `translateToCilium` as a proper enforcer API.** If/when a second enforcer appears, this is where the abstraction pays for itself.
