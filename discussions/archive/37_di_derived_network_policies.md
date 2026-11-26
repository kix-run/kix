# 37 — DI-Derived Network Policies

## Status

Draft (2026-03-26)

## Problem

kix already knows the full dependency graph between instances: the DI resolution
tells us *who* depends on *whom*, and the Nix string context in manifests tells us
*which specific resource* references *which other resource*. This is a complete
communication topology — yet we generate no NetworkPolicies from it, leaving
clusters either wide-open or requiring hand-written policies that duplicate what
the compiler already knows.

## Core insight

**DI resolution is a network graph.** When immich declares `postgres` as a
function argument and the evaluator resolves it, that edge means "immich's
workloads need to reach postgres's Service." The store-path context on
`postgres.out.fqdn` in the Deployment's env vars tells us *exactly which
Deployment talks to which Service*. The Service's `spec.ports` tells us the
allowed ports. The workload's `spec.selector.matchLabels` and the Service's
`spec.selector` give us the pod selectors for both sides.

Every field needed for a NetworkPolicy is already in the manifests. No new
metadata required.

## Relation to earlier connection-graph discussions

Documents 30/33/34 explored a broader "connection graph" concept — auto-deriving
`out.ports`, making every DI dep a connection by default, package-level opt-out,
and platform-level `connectsTo` for things like Prometheus scraping.

This RFC takes a narrower, more mechanical approach: **derive NetworkPolicies
directly from the existing resource dependency graph**, without introducing a
separate "connection" abstraction. The key difference: documents 30-34 proposed
that packages explicitly declare or opt out of connections. This RFC argues the
information is already there — in the DI edges and the store-path DAG — and a
separate declaration layer is unnecessary for the NetworkPolicy use case.

If the broader connection graph is implemented later (for visualization, impact
analysis, etc.), the NetworkPolicy derivation described here would be one consumer
of that graph. But it doesn't need to wait for it.

## Design

### Cluster-level opt-in

```nix
# In cluster definition
{
  networkPolicy = {
    enable = true;         # Generate NetworkPolicies from DI graph
    defaultDeny = true;    # Generate deny-all baseline per namespace
    directions = "both";   # "ingress" | "egress" | "both"
    provider = "kubernetes"; # Future: "cilium" for CiliumNetworkPolicy CRDs
  };
}
```

`enable = false` by default — no NetworkPolicies unless the operator opts in.

`provider` controls the output resource type. `"kubernetes"` emits standard
`networking.k8s.io/v1 NetworkPolicy`. `"cilium"` would emit
`cilium.io/v2 CiliumNetworkPolicy` with richer L7 capabilities. The derivation
logic is the same; only the manifest shape changes.

### Where policies are generated

NetworkPolicies are generated **per instance**, as part of that instance's
resource output — semantically they belong to the instance, not the cluster.
They sit alongside the Deployment, Service, etc. in the instance's `parts`.

This means:
- They participate in the existing resource DAG (store-path tracking)
- They show up in `kix-diff` as part of the instance
- They are scoped to the instance's namespace
- Package-level overrides can suppress or customize them

### Derivation algorithm

For each instance, after DI resolution and the build phase:

#### 1. Identify network edges

Two sources of edges, both already computed:

**Cross-instance edges** (from `resolvedDepMeta`):

For each resolved dependency, the current instance's resources may reference
the dep instance's resources. Walk the current instance's workload resources
(Deployment, StatefulSet, DaemonSet) and check their `rawManifest` string
context for store paths belonging to the dep's resources. Filter to edges
where the target is a Service.

```
workload in current instance  →  Service in dep instance
```

The Service's `spec.ports` gives us the allowed ports.
The workload's `spec.selector.matchLabels` gives us the source pod selector.
The Service's `spec.selector` gives us the target pod selector.

**Intra-instance edges** (from `parts`):

Same logic but within the instance's own resources. If a Deployment references
a Service in the same instance (e.g., Harbor's internal components), that's a
network edge too.

#### 2. Build per-workload policies

For each workload in the instance:

**Egress rules**: For each Service the workload references (via context):
```yaml
- to:
    - podSelector:
        matchLabels: <Service's spec.selector>
      namespaceSelector:          # only if cross-namespace
        matchLabels:
          kubernetes.io/metadata.name: <target namespace>
    ports:
      - port: <Service port>
        protocol: <Service protocol>
```

**Ingress rules**: Inverse — for each *other* workload (in any instance) that
references *this instance's* Services, allow traffic from that workload's pods
to the Service's ports.

This requires the inverse dependency graph: "who references my Services?"
The evaluator already computes inverse deps for orphan detection
(`inverseDeps`). The same technique applies here, but scoped to cross-instance
Service references.

#### 3. Generate the NetworkPolicy resource

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: <instanceName>-<workloadName>
  namespace: <namespace>
  labels:
    kix.dev/derived: "true"
    kix.dev/instance: <instanceName>
spec:
  podSelector:
    matchLabels: <workload's selector>
  policyTypes: [Ingress, Egress]  # or subset per config
  ingress: [...]
  egress: [...]
```

One NetworkPolicy per workload, combining all its ingress and egress rules.

### Default deny

When `defaultDeny = true`, generate a deny-all policy per namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: <namespace>
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
```

This is a namespace-level resource (not instance-level), generated alongside
the Namespace resource.

### DNS egress

With default-deny + egress policies, pods can't reach kube-dns unless
explicitly allowed. Generate a blanket DNS egress rule for every workload
policy:

```yaml
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
        podSelector:
          matchLabels:
            k8s-app: kube-dns
    ports:
      - port: 53
        protocol: UDP
      - port: 53
        protocol: TCP
```

This is always included when egress policies are generated. The `kube-system`
namespace and `kube-dns` labels are standard across distributions but could be
made configurable in `networkPolicy` config if needed.

### External traffic (Ingress resources)

When a package creates an `Ingress` resource, the ingress controller needs to
reach the backend Service. This is derivable:

1. The Ingress resource's `spec.rules[].http.paths[].backend.service` names a
   Service
2. The Ingress resource references the ingress controller via
   `spec.ingressClassName` (which comes from `ingressNginx.out.ingressClassName`
   — a DI reference with store-path context)

So the edge is: **ingress controller's workload → backend Service**, and the
store-path context already captures it. The ingress controller's Deployment
references the Ingress resource (or its class), which references the backend
Service. The ports come from the Ingress backend's `service.port`.

Additionally, the ingress controller itself needs to accept traffic from
outside the cluster. This is not a DI edge — it's an infrastructure concern.
The ingress-nginx package should declare this:

```nix
meta.network.externalIngress = true;
```

When this is set, the generated NetworkPolicy for that workload includes an
ingress rule with an empty `from` (allow all sources). This is the one piece
of metadata that can't be derived — the decision to expose something externally
is a policy choice, not a structural one.

### Optional dependencies

If a package declares `machineLearning ? null` and DI resolves it to an actual
instance, the network edge exists and a policy is generated. If it stays `null`,
no edge, no policy. The resolution result in `resolvedDepMeta` already
distinguishes these cases.

## Side thought: ingress vs egress vs both

The `directions` config controls which policy types are generated. What drives
this choice?

**Ingress-only** is the common starting point. It answers "who can talk to this
pod?" and is sufficient for most security postures. It's also the least
disruptive to adopt — egress is unrestricted, so pods can still reach external
services (package registries, APIs, etc.) that aren't modeled in the DI graph.

**Egress** is where it gets interesting. With egress policies, a pod can *only*
talk to the Services the DI graph says it should. This is a much stronger
security posture but it's also more likely to break things:

- Pods that call external APIs (webhook receivers, S3, SMTP) have no DI edge
  for those. You'd need an escape hatch — either `meta.network.allowExternalEgress = true`
  or explicit CIDR allowlists in the package meta.
- Init containers and sidecar patterns (istio, linkerd) inject network
  requirements that the DI graph doesn't model.
- Some packages communicate with the K8s API server (controllers, operators).
  This is partially derivable from RBAC — if a package creates RBAC resources,
  it likely talks to the API server — but that's a heuristic.

**Recommendation**: Default to `"both"` for maximum security, but expect that
packages will need to declare `meta.network.allowExternalEgress` or
`meta.network.extraEgress` for non-DI network access. The first rollout will
surface these gaps, and packages can be updated incrementally.

A pragmatic migration path: start with `directions = "ingress"` to lock down
inbound traffic (low risk), then switch to `"both"` once packages have
declared their external egress needs.

## Implementation sketch

### Phase 1: Edge collection

Add to `evaluateInstance`, after `resolvedDepMeta` and the build phase:

```nix
# Collect all workloads and services from parts
workloads = filter isWorkload allPartResources;
services = filter isService allPartResources;

# For each workload, find which Services it references (via context)
workloadEdges = map (w:
  let
    ctx = builtins.getContext (builtins.toJSON w.rawManifest);
    # Check against dep instances' resources AND own instance's resources
    targetServices = filter (svc:
      builtins.hasAttr (discardCtx svc.outPath) ctx
    ) (ownServices ++ depServices);
  in
  { workload = w; targets = targetServices; }
) workloads;
```

`depServices` comes from `resolvedDepMeta` — for each resolved dep, collect
its Service resources from `depInfo.instance.raw`.

### Phase 2: Inverse edges (for ingress rules)

The tricky part: instance A needs to know that instance B's workload references
A's Service. This is the reverse direction.

Options:

**A. Cluster-level post-pass**: After all instances are built, walk the full
graph and inject ingress rules back. This breaks the "policies belong to the
instance" principle but is straightforward.

**B. Fixpoint**: The outer `allInstances` fixpoint already allows circular
references. Instance A could look at all instances that depend on it (by
checking `resolvedDepMeta` of all instances). But this means every instance
must inspect every other instance — O(n^2) and possibly forcing unnecessary
evaluation.

**C. Egress-only per instance, ingress at namespace level**: Each instance
generates its own egress rules (it knows what it talks to). Ingress rules are
generated as a namespace-level pass that aggregates all egress edges targeting
services in that namespace. The ingress NetworkPolicy lives on the namespace,
not the instance.

**Recommended: Option C.** Egress is instance-local (each instance knows its
outbound edges). Ingress is namespace-scoped (the namespace aggregates all
inbound edges from other instances). This avoids the fixpoint complexity and
keeps instance evaluation independent.

### Phase 3: Policy generation

Convert edges to NetworkPolicy manifests using `scope.mkResource`. Tag with
`kix.dev/derived: "true"` so operators can distinguish generated from manual
policies.

### Phase 4: Provider abstraction

Behind the `provider` config, swap the manifest template:
- `"kubernetes"` → `networking.k8s.io/v1 NetworkPolicy`
- `"cilium"` → `cilium.io/v2 CiliumNetworkPolicy` (supports L7 rules, DNS
  policies, FQDN-based egress — useful for the external API egress problem)

## What this unlocks beyond security

Once the network graph is materialized as data:

- **`kix impact`**: "If I change postgres's port, what breaks?" — follow the
  edges to find all workloads that reference it.
- **`kix graph --network`**: Visualize the actual communication topology.
- **Drift detection**: Compare generated policies against live policies to find
  manually-added rules that should be codified.
- **Blast radius**: Before deploying a change, show which network paths are
  affected.

## Open questions

1. **Port remapping**: A Service may expose port 80 but target container port
   3000. The NetworkPolicy should use the Service port (what the client
   connects to) or the target port (what the pod listens on)? For standard
   NetworkPolicies, `spec.ingress[].ports[].port` matches the *destination
   pod's port*, so we need `targetPort`, not `port`. Need to verify this is
   always available in the Service spec.

2. **Headless Services**: `ClusterIP: None` Services don't proxy — clients
   connect directly to pod IPs. The NetworkPolicy derivation still works
   (same selectors and ports) but worth calling out.

3. **StatefulSet stable network identities**: StatefulSet pods get individual
   DNS names (`pod-0.service.ns`). The NetworkPolicy still uses label selectors,
   so this doesn't change the derivation. But it's worth noting that we can't
   generate per-pod policies this way.

4. **Jobs and CronJobs**: These create pods that may need network access but
   don't have persistent selectors. They do have labels though, so the same
   approach works — but the workload detection needs to include Job/CronJob.

5. **`kix-import` packages (Helm wraps)**: Helm-rendered manifests go through
   `mkResource` and get store paths, so context tracking works. But their
   internal wiring (Helm template cross-references) won't have context edges
   since they're rendered as opaque strings. Intra-package policies for
   Helm-wrapped packages may be incomplete.
