# 49 — Topology-Aware Monitoring: Graph-Derived Observability Configuration

**Status:** Design exploration
**Related:** `34_connection_graph_consolidated.md` (connection graph), `37_di_derived_network_policies.md` (DI-derived netpol), `48_system_contracts.md` (system contracts), `business_discussions/03_strategy.md` (Datadog positioning)

---

## The Insight

kix already has a complete structural dependency graph. The same graph that derives NetworkPolicies (doc 37) and validates system contracts (doc 48) contains all the topology information needed to **auto-generate monitoring, alerting, and observability configuration** — the thing that makes Datadog worth $30B.

The value proposition isn't "kix replaces Datadog." It's: **kix generates the monitoring configuration that tools like Prometheus, Grafana, and Alertmanager need, derived from the same graph that already generates NetworkPolicies and deployment order.** The topology is a free byproduct of the compilation step. Every other monitoring setup requires manual wiring or runtime discovery.

## The Datadog Lesson

From `business_discussions/03_strategy.md`:

> Datadog vs Prometheus. Prometheus can do everything Datadog does. Datadog has a $30B market cap because it sells operational burden displacement and **cross-boundary correlation**, not metrics.

Datadog's moat is two things:

1. **You don't need the person who runs Prometheus.** Operational burden displacement.
2. **When DNS breaks, Datadog shows you which services are affected.** Cross-boundary correlation — knowing the topology.

Point (1) is a SaaS play kix doesn't need to compete with. Point (2) is something kix gets **for free** — the dependency graph IS the topology. Every other monitoring setup has to discover this topology at runtime (service mesh sidecars, distributed tracing, traffic analysis). kix knows it at compile time.

## What kix Can Generate From the Graph

### Level 1: Per-Package Monitoring Artifacts (straightforward)

Each kix package already produces K8s manifests. It can equally produce:

- **PrometheusRule** resources — alerting rules specific to this package's known failure modes
- **ServiceMonitor/PodMonitor** resources — scrape targets auto-derived from service ports
- **Grafana dashboard ConfigMaps** — pre-built dashboards for each package's metrics
- **Alertmanager routing rules** — who gets paged when this package breaks

This is what already partially exists (Prometheus DI gates ServiceMonitor creation in immich, harbor, coredns). The gap is making it systematic: every package ships its own monitoring artifacts as part of the compiled output.

```nix
# What a package could declare
meta.monitoring = {
  metrics.port = 9090;
  metrics.path = "/metrics";
  alerts = {
    highErrorRate = {
      expr = "rate(http_requests_total{status=~\"5..\"}[5m]) > 0.05";
      severity = "warning";
      description = "Error rate above 5%";
    };
  };
  dashboard = ./grafana-dashboard.json;  # Optional: bundled dashboard
};
```

Nothing novel here — this is just "monitoring-as-code" baked into the package format.

### Level 2: Topology-Aware Alerting (the interesting part)

This is where the graph adds real value. The compiler knows the full dependency DAG, so it can generate **correlation-aware** alerting rules that no manually-configured Prometheus setup would produce:

**Blast radius alerts:** When a foundational service degrades, auto-generate grouped alerts for its dependents.

```yaml
# Auto-generated: "coredns is a dependency of 14 packages"
- alert: CoreDNS_Degraded_BlastRadius
  expr: coredns_dns_responses_total{rcode="SERVFAIL"} > 0
  annotations:
    blast_radius: |
      immich, harbor, n8n, metabase, velero, prometheus,
      grafana, cert-manager, ingress-nginx, ...
    severity_boost: "14 packages depend on this"
```

**Correlated error suppression:** If DNS is down and 14 services start erroring, suppress the downstream noise and point at the root cause.

```yaml
# Auto-generated inhibition rule
- source_match:
    alertname: CoreDNS_Degraded
  target_match_re:
    # All packages that declare coredns as a dependency
    kix_package: "immich|harbor|n8n|metabase|..."
  equal: ['cluster']
```

This is the "trivial" part the user identified: **the graph directly encodes which downstream errors are likely caused by which upstream failures.** Alertmanager inhibition rules are the mechanism; the kix graph is the source of truth for which inhibitions to create.

**Dependency-chain health dashboards:** Auto-generate a Grafana dashboard that shows the health of a package AND all its transitive dependencies, ordered by graph depth.

```
immich health view (auto-generated):
├── immich-server     ✓ healthy
├── postgres          ✓ healthy
│   └── storage-pvc   ✓ bound
├── valkey            ✓ healthy
├── ingress-nginx     ⚠ elevated 5xx
│   └── cert-manager  ✓ healthy
└── coredns           ✓ healthy
```

### Level 3: Connection-Graph-Derived Monitoring (builds on doc 34)

Once the connection graph (doc 34) is implemented — where kix knows not just "A depends on B" but "A sends TCP traffic to B on port 5432" — the monitoring generation becomes even richer:

- **Per-connection latency alerts** — "immich → postgres p99 latency > 100ms"
- **Connection-specific error rates** — not just "postgres has errors" but "the immich-to-postgres connection has errors"
- **Traffic flow dashboards** — auto-generated from the connection graph, showing actual data paths

This requires the connection graph to exist first. It's a future enhancement, not a prerequisite.

## Service Meshes: What They Do and Where kix Overlaps

Service meshes (Istio, Linkerd, Cilium) solve a related but different problem. Understanding the overlap is important for positioning.

### What a service mesh provides

| Capability | How it works | Runtime/compile-time |
|---|---|---|
| **mTLS everywhere** | Sidecar/eBPF intercepts all pod traffic, encrypts it | Runtime — transparent to apps |
| **Traffic observability** | Sidecar reports L7 metrics (request rate, latency, error rate per connection) | Runtime — discovered from actual traffic |
| **Traffic management** | Canary routing, retries, timeouts, circuit breaking per-route | Runtime — configured via CRDs (VirtualService, etc.) |
| **Access control** | AuthorizationPolicy (Istio) / NetworkPolicy++ | Runtime — enforced by proxy |
| **Runtime topology discovery** | "Who talks to whom" derived from observed traffic | Runtime — requires traffic to flow first |

### What kix already provides or can provide without a mesh

| Capability | kix mechanism | Compile-time/runtime |
|---|---|---|
| **Network access control** | DI-derived NetworkPolicies (doc 37, implemented) | Compile-time — no proxy needed |
| **Topology / who-depends-on-whom** | Dependency graph + connection graph (doc 34) | Compile-time — known before any traffic flows |
| **Blast radius analysis** | Graph traversal on the dependency DAG | Compile-time — this doc |
| **Per-package monitoring config** | PrometheusRule, ServiceMonitor, dashboards as package artifacts | Compile-time generation, runtime execution |
| **Correlated alerting / inhibition** | Alertmanager inhibition rules derived from graph edges | Compile-time generation, runtime execution |

### What kix CANNOT replace (service mesh stays)

- **mTLS** — encrypting pod-to-pod traffic requires a runtime proxy or eBPF. kix generates manifests, not network encryption. A service mesh or Cilium is still needed for zero-trust networking.
- **L7 traffic metrics** — actual request rate, latency percentiles, and error rates per connection require a sidecar or eBPF that intercepts live traffic. kix knows the *declared* topology but not the *observed* traffic patterns. This is the data source that feeds Level 3 monitoring.
- **Runtime traffic management** — canary splits, retries, circuit breaking, rate limiting. These are fundamentally runtime decisions based on live traffic conditions.
- **Runtime topology discovery** — kix knows the declared graph, not the actual traffic. A service mesh can discover undeclared connections (e.g., a pod calling an external API that isn't in the kix graph). Both views are complementary.

### What kix could make a service mesh BETTER at (or partially obsolete)

**Access control (partial replacement):**
DI-derived NetworkPolicies (doc 37) already replace the basic "who can talk to whom" function of a service mesh's authorization policies. For L3/L4 access control, kix-generated Cilium NetworkPolicies + Cilium's eBPF enforcement can replace Istio entirely. The gap: L7 policies (e.g., "allow GET /health but deny POST /admin") still need a mesh or gateway.

**Configuration of the mesh itself:**
If a service mesh IS deployed, kix can generate its CRDs from the graph:

```nix
# Auto-generate Istio VirtualService from the connection graph
# If immich connects to postgres on port 5432, generate:
#   - DestinationRule with connection pool settings
#   - VirtualService with timeout/retry defaults
#   - PeerAuthentication for mTLS mode
```

This is the same pattern as NetworkPolicies — the mesh is the enforcement runtime, kix is the configuration compiler. Today, people hand-write Istio CRDs. kix could derive them.

**Topology that doesn't require traffic:**
Service meshes discover topology by observing traffic — but this means they can't show you the topology of a service that hasn't received traffic yet, or a new deployment that just rolled out. kix's compile-time topology is available immediately and completely, before the first request. The two views are complementary: kix provides the "intended" graph, the mesh provides the "actual" graph.

**Making the mesh thinner:**
The end state isn't "no service mesh" but "a much thinner mesh." If kix handles access control (NetworkPolicies), configuration (CRD generation), topology (graph), and alerting (this doc), the service mesh reduces to:
1. mTLS encryption (Cilium eBPF can do this without sidecars)
2. L7 traffic metrics (for runtime observability that feeds back into the graph)
3. Traffic management (canary, retries — only when needed)

For clusters that don't need L7 policies or advanced traffic management, **Cilium alone (no Istio/Linkerd) + kix-generated NetworkPolicies + kix-generated monitoring** could be the entire "service mesh" story. This is a significant simplification.

## Relationship to the Platform Story

From the business discussions, kix's platform business bundles monitoring as an included service:

> | Current state (AWS + tools + team) | kix platform |
> |---|---|
> | Tooling (Datadog, Akuity, etc.): 2-5k/month | Included in platform |

This feature makes that real. A kix-managed cluster ships with:
- Pre-configured Prometheus scraping (ServiceMonitors for every package)
- Pre-configured alerting rules (PrometheusRules for every package, plus topology-aware inhibitions)
- Pre-configured dashboards (Grafana dashboards for every package, plus dependency-chain views)
- Pre-configured access control (NetworkPolicies from the graph)

The customer doesn't configure monitoring. They deploy packages, and monitoring appears. This is the Datadog value proposition — "find the problem faster" — delivered through compile-time graph analysis rather than a $30B SaaS platform.

## Implementation Phases

### Phase 1: Package-level monitoring artifacts
- Add `meta.monitoring` convention to package format
- Prometheus DI gates ServiceMonitor/PrometheusRule generation (partially exists)
- Ship monitoring packages (prometheus, grafana, alertmanager) with auto-configuration from the cluster graph

### Phase 2: Topology-aware alerting
- Generate Alertmanager inhibition rules from dependency graph edges
- Generate blast-radius annotations on alerts
- Auto-generate dependency-chain health dashboards

### Phase 3: Connection-graph-derived monitoring (depends on doc 34)
- Per-connection alerting rules from the connection graph
- Auto-generate service mesh CRDs (Istio/Cilium) from the connection graph
- Feed runtime L7 metrics back into the compile-time graph for drift detection ("declared topology says A→B, but traffic shows A→C")

### Phase 4: Feedback loop
- Runtime health data informs the compile-time graph (inline operator pattern from roadmap)
- "What would break if I remove this package?" uses both declared deps AND observed traffic
- Anomaly correlation: runtime error spike + graph traversal = probable root cause
