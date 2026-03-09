# 01: Manifests Derived FROM Config, Not BE the Config

## The Problem

Currently, cross-cutting modules read from `config.manifests.*`:

```nix
# monitoring.nix reads monitoring.targets which contain manifest-level details:
monitoring.targets.coredns = {
  serviceName = "coredns-metrics";      # ← K8s resource name
  portName = "metrics";                 # ← K8s port name
  selector = selectorLabels // { ... }; # ← K8s label selector
};
```

This is better than reading `config.manifests."coredns-deployment".metadata.labels`
directly, but the target declaration still contains implementation details: Kubernetes
service names, port names, and label selectors. These are properties of the MANIFEST,
not properties of the SERVICE.

If the monitoring implementation changes from Prometheus (which needs label selectors)
to Datadog (which uses annotations), every chart's target declaration needs to change.
The chart is coupled to the monitoring implementation's needs.

Luca's principle: **higher-level modules should have NOTHING to do with lower-level
manifests.** The manifests should be derived from the config instead.

## What This Means Concretely

The current flow:

```
Chart options (services.coredns.*)
  ↓ chart reads options, builds K8s resources
  ↓ chart also declares monitoring targets with K8s-level details
config.manifests (attrsets containing K8s resources)
  ↓ monitoring module reads targets
  ↓ monitoring module creates ServiceMonitor K8s resources
  ↓ mkManifests serializes everything
YAML files
```

The proposed flow:

```
Chart options (services.coredns.*)
  ↓ chart declares abstract capabilities: "I have metrics on port 9153"
Capability interfaces (capabilities.monitoring.coredns)
  ↓ capability modules read declarations
  ↓ capability modules write back to charts: "put these labels on your pods"
  ↓ charts read capability output when building resources
config.manifests (terminal output — nothing reads from this)
  ↓ mkManifests serializes
YAML files
```

The critical difference: `config.manifests` becomes a write-only output. No module
reads from it. All cross-module communication happens through options at the
capability/registry layer.

## Options Considered

### Option A: Keep current design, accept the coupling

Leave `monitoring.targets` as-is. Charts declare targets with K8s-level details.
The monitoring module creates ServiceMonitors.

**Pros**: Already works. 42 checks pass. Simple.
**Cons**: Every chart is coupled to Prometheus concepts (selectors, port names).
Adding a new monitoring backend requires changing every chart. Tight coupling
defeats the purpose of abstractions.

### Option B: Abstract monitoring targets (remove K8s details)

Change `monitoring.targets` to abstract declarations:

```nix
monitoring.targets.coredns = {
  port = 9153;
  path = "/metrics";
};
```

The monitoring module figures out the K8s-level details (selectors, ServiceMonitor
structure) from other config. This is a half-measure — better than A, but the
monitoring module still needs to know how to find the chart's Service.

**Pros**: Charts don't know about Prometheus.
**Cons**: Monitoring module still needs chart-specific knowledge (which Service
to target, what namespace, etc.).

### Option C: Capability interfaces with bidirectional flow (recommended)

Charts declare abstract capabilities. Implementation modules read these and
write back what the chart needs to do to support them. See `03-inversion-of-control.md`
for the full design.

```nix
# Chart declares:
capabilities.monitoring.coredns = { port = 9153; path = "/metrics"; };
# Chart reads back:
monitoringLabels = config.capabilities.monitoring.coredns.labels or {};
# Implementation module creates ServiceMonitor resources
```

**Pros**: Zero coupling between charts and implementations. Charts don't know
about Prometheus, Datadog, or any specific monitoring system. Implementations
can be swapped without touching charts. `config.manifests` becomes terminal output.

**Cons**: More indirection. New abstraction layer to learn. Bidirectional option
flow requires careful understanding of the module system's merge semantics.

## Recommendation

**Option C.** This is the fundamental architectural shift Luca is pointing at.
The current monitoring.targets pattern was a step in the right direction (separating
intent from materialization), but it didn't go far enough — charts still speak
K8s-level details to the monitoring module.

The test for whether the abstraction is right: can you swap Prometheus for Datadog
without changing any chart code? With Option C, yes. With A or B, no.

## Impact on Existing Code

- `modules/monitoring.nix` — Major rewrite. Becomes a capability implementation.
- `modules/registry.nix` — Already close to the right pattern (charts declare,
  consumers read). May become a capability itself.
- `pkgs/*/resources.nix` — extraConfig sections change from `monitoring.targets.*`
  to `capabilities.monitoring.*`. Simpler declarations (just port/path).
- `flake.nix` — `validateManifestSet` may become unnecessary if capability
  interfaces provide structural guarantees (see `08-questions-for-luca.md`).
- `lib/default.nix` — No changes needed to kixlib builders.
