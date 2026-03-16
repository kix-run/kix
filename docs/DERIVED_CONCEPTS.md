# Kix v2: Concepts Derived from Package Structure

## Table of contents

- [Part 1: Structural derivations](#part-1-structural-derivations)
  - [1. Network policies (ingress + egress)](#1-network-policies-ingress--egress)
  - [2. Deployment ordering / sync waves](#2-deployment-ordering--sync-waves)
  - [3. Init containers for dependency readiness](#3-init-containers-for-dependency-readiness)
  - [4. Egress DNS allowlists / Cilium FQDN policies](#4-egress-dns-allowlists--cilium-fqdn-policies)
  - [5. Multi-layer policy projection](#5-multi-layer-policy-projection)
  - [6. Namespace lifecycle](#6-namespace-lifecycle)
  - [7. Certificate trust topology (non-mesh mTLS)](#7-certificate-trust-topology-non-mesh-mtls)
- [The meta-insight](#the-meta-insight)
- [Part 2: Helpers and smart defaults](#part-2-helpers-and-smart-defaults)
  - [PodDisruptionBudgets from replica count](#poddisruptionbudgets-from-replica-count)
  - [Anti-affinity from multi-instance](#anti-affinity-from-multi-instance)
  - [ServiceMonitors from port conventions](#servicemonitors-from-port-conventions)
  - [Ingress + TLS + DNS bundles](#ingress--tls--dns-bundles)
  - [Namespace ResourceQuotas from resource sums](#namespace-resourcequotas-from-resource-sums)
  - [PriorityClasses from environment tier](#priorityclasses-from-environment-tier)
  - [Backup annotations from PVC presence](#backup-annotations-from-pvc-presence)
- [Part 3: Helpers as capabilities](#part-3-helpers-as-capabilities)
  - [Two shapes of module output](#two-shapes-of-module-output)
  - [The three capabilities](#the-three-capabilities)
  - [Summary table](#summary-table)
  - [Helper-by-helper analysis](#helper-by-helper-analysis)

---

Kix v2's dependency graph contains information that K8s normally makes you
duplicate manually. The question is: which K8s concepts are **mechanically
derivable** from that graph — meaning the graph is the authoritative source of
truth, not merely a correlated heuristic?

The test: the information must **originate** in the dependency graph, not merely
be echoed by it. A PDB from replica count is just a default — the replica count
doesn't structurally cause the disruption policy. A network policy from the dep
graph is different — the graph IS the source of truth for allowed communication.
The K8s resource is a mechanical projection, not a convention.

---

## Part 1: Structural derivations

These pass the test. The dependency graph is the authoritative source.

### 1. Network policies (ingress + egress)

If package A interpolates `"${postgres.fqdn}:${postgres.out.port}"`, we know:
- A needs egress to postgres on that port
- postgres needs ingress from A on that port

Default-deny everything else. The dep graph IS the network policy. No manual
CiliumNetworkPolicy needed.

**Caveat:** The graph captures *declared* communication — dependencies expressed
via `${}` interpolation. Communication not captured in the graph (hardcoded
hostnames in container images, URLs from runtime config) won't get allow rules.
The graph is authoritative for what it captures, but it's a lower bound on
allowed communication. Default-deny on an incomplete graph will break things, so
packages must declare all their communication targets.

### 2. Deployment ordering / sync waves

Topological sort of the package dependency graph gives you rollout order. If
`app` takes `postgres` as an argument and interpolates `${postgres.fqdn}`,
postgres must exist before app.

**Derived resources:** ArgoCD sync-wave annotations, Flux Kustomization
dependencies, or plain "apply in this order" sequencing.

**Authoritative?** Yes. The dependency graph IS the ordering constraint. There is
no other source of truth for "what must exist before what." A human maintaining
`sync-wave: "2"` annotations by hand is duplicating information that already
lives in the graph — and getting it wrong causes cascading startup failures.

**Deletion ordering** is the same derivation in reverse: delete dependents before
dependencies. Delete the app before postgres, not the other way around.

**Edge cases:** Circular dependencies are caught at Nix eval time (infinite
recursion), so this is naturally validated. Soft dependencies (app retries until
postgres is up) don't strictly need ordering, but conservative ordering is always
safe and costs nothing. Soft cycles (A health-checks B, B health-checks A, but
neither interpolates the other's FQDN in its resource spec) won't be caught by
the graph and would deadlock if both get init-container waits.

**Scale problem:** In a cluster with 50+ packages, manually maintaining
deployment order is a combinatorial nightmare that humans reliably get wrong
during refactors.

### 3. Init containers for dependency readiness

Same edges as network policies. If `app` interpolates
`${postgres.fqdn}:${toString postgres.out.port}`, generate an init container
that does `nc -z $FQDN $PORT` in a loop.

**Authoritative?** Yes. The graph knows exactly what A needs before it can
function, and on which port. The init container is a mechanical projection of "A
cannot do useful work until B is reachable at this endpoint." No human judgment
needed.

**Edge cases:** Some dependencies are lazy (app handles reconnection gracefully).
You could add an `optional` marker on the dependency edge, but the conservative
default (wait for all deps) is correct. The graph also doesn't know about
authentication readiness (postgres might be listening but not accepting
connections yet) — but `pg_isready` style checks could be generated if the graph
captures the dependency *type*.

**Scale problem:** Init containers are the most error-prone piece of
hand-maintained YAML. Teams forget to update them when dependencies change,
leading to pods that start before their database is ready.

### 4. Egress DNS allowlists / Cilium FQDN policies

The graph knows every FQDN every package references — both internal
(`${postgres.fqdn}` -> `postgres.default.svc.cluster.local`) and external (if
packages declare external dependencies like `s3.amazonaws.com`). Anything not in
the graph is denied.

**Derived resources:** Cilium `CiliumNetworkPolicy` with `toFQDNs` rules. No
human curates an allowlist — the allowlist IS the dependency declarations.

**Edge cases:** Dynamic DNS works fine — Cilium intercepts DNS responses via its
DNS proxy and maps FQDNs to observed IPs, so IP changes are tracked
automatically. The main gap is if application code makes DNS lookups that
aren't captured in Nix interpolation (e.g., a URL read from a ConfigMap at
runtime). But that's a case where the dependency should have been declared and
wasn't — the graph correctly flags its absence.

**Scale problem:** Egress allowlists are one of the most tedious and error-prone
security controls. Teams either don't bother (allow-all egress) or maintain stale
lists that break when dependencies change.

### 5. Multi-layer policy projection

A single dependency edge (`app -> postgres on port 5432`) generates the same
structural fact projected to every enforcement layer:

- **NetworkPolicy**: allow `app` -> `postgres` on TCP/5432
- **CiliumNetworkPolicy**: same at L3/L4. L7 protocol filtering (e.g., only Postgres wire protocol) would require the graph to carry protocol type metadata beyond just port numbers
- **Istio AuthorizationPolicy**: allow `app`'s identity to reach `postgres` on port 5432 (requires a convention that each package gets its own ServiceAccount, since Istio AuthZ uses SPIFFE identities derived from SAs)
- **Kyverno/OPA policy**: reject any Pod spec that mounts a service account token with broader network access than the graph declares

**Authoritative?** Yes — all layers express the same structural fact. The graph
is the single source of truth; each K8s/mesh/policy resource is a projection to
a different enforcement plane. Defense in depth without any additional human
input.

**Why this matters:** In practice, teams maintain NetworkPolicies and Istio
AuthorizationPolicies as separate, uncoordinated YAML files. They drift. An app
gets a new dependency, someone updates the NetworkPolicy but forgets the
AuthorizationPolicy (or vice versa). The graph eliminates this class of
inconsistency entirely.

**Edge cases:** Some policy layers have different granularity (NetworkPolicy is
pod-selector-based, Istio AuthZ is ServiceAccount-based). The graph needs to emit
the right selector type for each layer, but the underlying fact is the same.

### 6. Namespace lifecycle

The cluster topology `{ namespace -> { instance -> package } }` IS the set of
namespaces that should exist. Each namespace resource, its labels (for
NetworkPolicy selectors, pod security standards, etc.), and its annotations are
mechanical projections.

Orphan namespaces (exist in cluster but not in graph) are detectable. System
namespaces (`kube-system`, `kube-public`) are enumerable constants outside the
graph.

### 7. Certificate trust topology (non-mesh mTLS)

If you're managing TLS without a service mesh, the graph knows who talks to
whom, which means it knows:

- Which workloads need serving certificates (anything that IS a dependency)
- Which workloads need which CA bundles in their trust store (the CAs of their dependencies)
- The minimum set of cert-manager `Certificate` resources and `trust-manager` `Bundle` resources

**Authoritative?** Partially. The graph knows who communicates with whom, which
gives you a starting point for trust. But certificate trust is not always
isomorphic to communication topology: wildcard certificates serve multiple
services, intermediate CAs are shared across trust boundaries, and certificate
pinning requirements don't follow the dependency graph. Breaks down further if
you use a mesh (the mesh handles it) or need to trust external CAs.

---

## The meta-insight

The Merkle DAG is a **complete, content-addressed description of intended cluster
state and its causal structure.** Communication topology is one projection of
this. Ordering is another. Change detection is another. Any K8s concept that asks
"what should exist, what depends on what, and what changed?" is structurally
derivable. The graph has no access to runtime state (load, latency, pod status) —
Kix is purely eval-time. And some intent simply isn't captured in resource
references (how many replicas are acceptable to lose, whether storage is
precious). That's what capabilities (Part 3) are for: explicit declarations of
facts the graph can't infer.

Beyond the 7 derivations above, the DAG also enables:

- **Drift detection.** Comparing the hash of the last-applied closure against the
  current eval tells you exactly which resources changed, without diffing YAML.
- **Blast radius computation.** Given a changed resource, the reverse closure
  (everything that transitively depends on it) is the blast radius — useful for
  CI gatekeeping.
- **Orphan detection.** The set difference between cluster state and the computed
  closure identifies resources that should no longer exist. Section 6 notes this
  for namespaces, but it generalizes to all resource types.

---

## Part 2: Helpers and smart defaults

These don't pass the structural derivation test — the graph isn't the
authoritative source, it's just a convenient place to read correlated information.
Still useful as boilerplate reducers, just a different category.

### PodDisruptionBudgets from replica count

If a Deployment has `replicas = 3`, a sensible PDB (`minAvailable: 2` or
`maxUnavailable: 1`) is implied. Auto-generate one for every workload with
replicas > 1, with an opt-out for special cases.

**Why it's a helper:** The replica count doesn't structurally cause the
disruption policy. It's a sensible default, not a derived fact. Some workloads
with 3 replicas can tolerate all-at-once restarts; others with 2 replicas need
`maxUnavailable: 0` during maintenance.

### Anti-affinity from multi-instance

If the cluster definition has two instances of the same package, or a Deployment
with `replicas > 1`, topology spread constraints and pod anti-affinity can be
auto-generated.

**Why it's a helper:** Spreading is a sensible operational default, not a
structural consequence of the dependency graph. Some workloads explicitly want
co-location (latency-sensitive pairs).

### ServiceMonitors from port conventions

If a container declares a port named `metrics`, the ServiceMonitor can be
auto-generated. The package already knows the service name, namespace, port, and
labels.

**Why it's a helper:** The port name is a human convention, not a structural
fact. Not every port named "metrics" should be scraped, and some metrics
endpoints use non-standard names.

### Ingress + TLS + DNS bundles

Exposing a service externally requires an Ingress, a Certificate, and a DNS
annotation. These always travel together. A single `expose` declaration could
generate all three.

**Why it's a helper:** This is boilerplate reduction (three resources that always
appear together become one declaration), not structural derivation. The domain
name, ingress class, and TLS issuer are human choices, not graph-derived facts.

### Namespace ResourceQuotas from resource sums

Every container declares resource requests/limits. The ResourceQuota for a
namespace is the sum of all requests across all containers in that namespace.

**Why it's a helper:** It's an aggregation convenience. The quota is a policy
decision (how much should this namespace be allowed to use), not a structural
fact (how much it currently declares). Actual quotas often include headroom for
scaling.

### PriorityClasses from environment tier

If `mkEnv "prod"` creates production namespaces, pods in prod can auto-get
higher priority than staging.

**Why it's a helper:** Priority is an operational policy decision, not a
structural consequence of the package graph.

### Backup annotations from PVC presence

If a package creates PersistentVolumeClaims, Velero Schedule resources can be
auto-generated with `includedNamespaces` computed from which namespaces contain
persistent workloads. Stateless namespaces get excluded.

**Why it's a helper:** PVC presence is a heuristic for "needs backup." Some PVCs
hold ephemeral caches; some stateless workloads still need backup of their
ConfigMaps.

---

## Part 3: Helpers as capabilities

The v2 design already has a mechanism for this: **Capabilities + Modules**
(RFC doc 08, "Cross-Cutting Concerns"). The pattern is:

1. **Package declares a capability** — plain data about itself, not resources.
2. **Cluster operator enables a module** — with cluster-level policy config.
3. **Module iterates all instances**, reads capabilities, produces resources.

This separates package facts from cluster policy. A package says "I have 3
replicas." A cluster module says "things with replicas get PDBs." Staging
clusters can disable the PDB module without touching any package code.

### Two shapes of module output

**Shape 1 — New resources.** The module creates new K8s resources (ServiceMonitor,
PDB, Ingress, Certificate) and attaches them to the instance's closure via
`requires`. This is what the RFC describes. Clean, no coordination needed.

**Shape 2 — Mutations to existing resources.** The module needs to inject fields
into an existing resource's spec (anti-affinity into a Deployment's pod template,
priorityClassName into a pod spec). This is just `overrideParts` applied from
outside the package. The package declares a handle to the target resource (e.g.,
`workload = self.deployment`); the module applies `overrideParts` targeting that
handle to inject the extra fields. The inner fixpoint re-wires. No new mechanism
needed — modules are external overlays on the inner fixpoint, using the same
self/super pattern packages already use internally.

### The three capabilities

An earlier draft proposed five separate capabilities (`availability`, `resources`,
`monitoring`, `expose`, `storage`). These might collapse to three once you notice
the common thread: multiple modules need to target the same workload resource,
and `availability` and `resources` both carry `replicas`. One possible minimal
set (open for discussion):

**`workload`** — facts about the thing that runs pods:
```nix
capabilities.workload = {
  resource = self.deployment;               # handle for mutations
  replicas = cfg.replicas;
  requests = { cpu = "500m"; memory = "512Mi"; };
  limits = { cpu = "1"; memory = "1Gi"; };
  storage = {                               # optional
    persistent = true;
    pvcs = [ self."data-pvc" ];
  };
};
```

Consumed by: PDB, anti-affinity, priority, resource quota, and backup modules.
All need the workload handle; most need replicas or resource data. One
declaration, many consumers.

**`monitoring`** — facts about observability:
```nix
capabilities.monitoring = {
  endpoints = [{ port = "metrics"; path = "/metrics"; }];
  metricsService = self.service;
};
```

Consumed by: monitoring module (ServiceMonitor, Datadog, etc.). Targets a
Service, not a workload — distinct concern.

**`expose`** — facts about external ingress:
```nix
capabilities.expose = {
  service = self.service;
  port = 8080;
  domain = "app.example.com";
};
```

Consumed by: ingress module (Ingress + Certificate + DNS). Also targets a
Service. Distinct concern.

### Summary table

| Helper | Capability | What module reads | Cluster configures | Module output |
|---|---|---|---|---|
| PDB | `workload` | resource + replicas | default policy, overrides | New resource (shape 1) |
| Anti-affinity | `workload` | resource + replicas | topology key, max skew | Mutation (shape 2) |
| ResourceQuota | `workload` | requests + replicas | headroom %, overrides | New resource (shape 1) |
| PriorityClass | `workload` | resource (mutation target) | tier defs, namespace mapping | New resource + mutation |
| Backup | `workload` | storage.pvcs | provider, schedule, exclusions | New resource (Schedule) + mutation (pod annotations) |
| ServiceMonitor | `monitoring` | endpoints + metricsService | provider, default interval | New resource (shape 1) |
| Ingress bundle | `expose` | service + port + domain | ingress class ref, cert issuer ref, DNS | New resources (shape 1) |

### Helper-by-helper analysis

#### PDB + Anti-affinity + PriorityClass (all from `workload`)

All three consume `capabilities.workload.resource` and `.replicas`.

**PDB module config:**
```nix
modules.disruption-budgets = {
  enabled = true;
  defaultPolicy = { maxUnavailable = 1; };
  overrides.postgres.policy = { minAvailable = 1; };
};
```
Produces a PodDisruptionBudget (shape 1) targeting the workload's label selector.
Opt-in: no `capabilities.workload`, no PDB.

**Anti-affinity module config:**
```nix
modules.topology-spread = {
  enabled = true;
  defaultTopologyKey = "kubernetes.io/hostname";
  maxSkew = 1;
  whenUnsatisfiable = "DoNotSchedule";
};
```
Applies `overrideParts` on the workload to inject `topologySpreadConstraints`
into the pod template (shape 2).

**Priority module config:**
```nix
modules.priority = {
  enabled = true;
  tiers = {
    prod   = { value = 1000; preemptionPolicy = "PreemptLowerPriority"; };
    staging = { value = 500; };
    dev    = { value = 100; };
  };
  namespaceTiers = {
    "prod-*" = "prod";
    "staging-*" = "staging";
    "*" = "dev";
  };
};
```
Creates PriorityClass resources (shape 1) and applies `overrideParts` on the
workload to inject `priorityClassName` (shape 2). Priority is a cluster policy
decision — the package doesn't choose its own priority, but the module needs the
workload handle to know where to inject.

**Design note:** One capability, three modules. PDB creates a new resource.
Anti-affinity and priority mutate the existing workload via `overrideParts`. A
single module could handle all three, or they can be independent — the workload
handle is the stable contract between them.

#### ResourceQuota (from `workload`)

Reads `capabilities.workload.requests`, `.limits`, and `.replicas`.

**Module config:**
```nix
modules.resource-quotas = {
  enabled = true;
  headroomPercent = 20;
  overrides.production.hard."requests.cpu" = "100";
};
```

Produces a ResourceQuota per namespace from the sum of all workload declarations
(requests × replicas) plus headroom. Shape 1 — new resource.

Resource requests do exist in container specs, but extracting them requires
parsing across Deployments, StatefulSets, CronJobs, etc. — each nests containers
differently. The capability gives the module clean, structured data.

#### Backup (from `workload.storage`)

Reads `capabilities.workload.storage` (the optional sub-field).

**Module config:**
```nix
modules.backup = {
  enabled = true;
  provider = "velero";
  schedule = "0 2 * * *";
  excludeNamespaces = [ "dev-*" ];
};
```

Produces Velero Schedule resources with `includedNamespaces` computed from which
namespaces contain persistent workloads, plus pod-level
`backup.velero.io/backup-volumes` annotations (shape 2 via `overrideParts`).

Not every PVC needs backup — a Valkey cache might create a PVC for AOF that's
ephemeral. The `storage.persistent` flag is the package explicitly declaring "I
have state that matters."

#### ServiceMonitors (from `monitoring`)

**Module config:**
```nix
modules.monitoring = {
  enabled = true;
  provider = "prometheus";
  defaultInterval = "30s";
};
```

Produces a ServiceMonitor (shape 1) pointing at `capabilities.monitoring.metricsService`.
The v1 codebase already implements this pattern (v4 capability system). It's
proven. The capability is an explicit opt-in — the module doesn't guess from port
names.

#### Ingress bundle (from `expose`)

**Module config:**
```nix
modules.ingress = {
  enabled = true;
  ingressClass = ingressNginx.ingressClass;     # ref to IngressClass resource
  clusterIssuer = certManager.clusterIssuer;     # ref to ClusterIssuer resource
  externalDns.enabled = true;
};
```

Produces Ingress + cert-manager Certificate + external-dns annotation (all
shape 1). `ingressClass` and `clusterIssuer` are refs to real K8s resources, not
strings — the dependency graph should track that the Ingress depends on the
IngressClass existing.

The package says "I want to be reachable at app.example.com." The cluster decides
how. A staging cluster could use a different issuer or disable external-dns
without touching any package.
