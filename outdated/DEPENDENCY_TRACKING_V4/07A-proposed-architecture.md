# 07A: Proposed Architecture (Revised)

Supersedes 07-proposed-architecture.md. Incorporates all decisions from Luca's
feedback (section 10), Adam's big-bang migration decision, the composable
primitives deep dive, and concrete code analysis of the three existing charts.

## Design Principles

1. **Don't encode defaults, encode decisions.** Primitives and capabilities
   encode operational knowledge. Charts express intent, not K8s boilerplate.

2. **Registries are the API; pipes are the syntax.** Cross-cutting concerns use
   capability registries (NixOS-style option merging). Pipes (`|>`) are ergonomic
   sugar that desugar into registry declarations.

3. **config.manifests is terminal.** No module reads from it. All cross-module
   communication flows through typed options (capabilities, registry, exports).

4. **Capabilities have levels.** Monitoring, network policy, TLS = cluster-level
   (capability interfaces). Autoscaling, PDB, sidecars = application-level
   (resource group combinators that desugar to registries).

5. **Zero coupling between charts and implementations.** Charts declare abstract
   intent ("I have metrics on port 9153"). Implementations decide how to act
   ("create a ServiceMonitor matching a generic label"). Swap Prometheus for
   Datadog: zero chart changes.

## Contract Roles

Who is who in the kixpkgs ecosystem (Luca's mapping, approved):

| Role | kixpkgs Entity | Responsibility |
|------|---------------|----------------|
| **Contract maintainer** | kixlib + `modules/capabilities/` | Defines the monitoring/autoscaling/TLS interface shapes |
| **Provider** | `modules/implementations/` | Fulfills capabilities (creates ServiceMonitors, HPAs, etc.) |
| **Consumer** | `pkgs/*/resources.nix` | Declares capabilities, reads back outputs, builds resources |
| **End user** | `clusters/*.nix` | Enables services, sets cluster-level capability config |

**Adam's note**: These make useful Claude team member personas for evaluating
changes — "review this as the contract maintainer", "does this make sense from
the end user's perspective?"

## Layer Diagram

```
Layer 3: Cluster config (clusters/example.nix)
  Sets: services.coredns.enable = true
        monitoring.enabled = true; monitoring.provider = "prometheus"
  Overrides: capabilities.autoscaling.coredns.maxReplicas = 20  (optional)

Layer 2: Capability system
  Interfaces (modules/capabilities/):
    monitoring.nix   — "I have metrics" (port, path → labels, annotations)
    autoscaling.nix  — "I want to scale" (min, max, targetRef → controlledByAutoscaler)
    network-policy.nix — "I need network rules" (ports, peers → policy labels)

  Implementations (modules/implementations/):
    monitoring-prometheus.nix — reads declarations, writes generic labels,
                                creates ServiceMonitors
    monitoring-datadog.nix    — reads declarations, writes Datadog annotations,
                                no CRDs needed
    autoscaling-hpa.nix       — reads declarations, creates HPAs,
                                sets controlledByAutoscaler = true

  Bidirectional flow: implementations write labels/annotations BACK to
  capability options. Charts read them. Module system merges both sides.

Layer 1: Chart modules (pkgs/*/resources.nix)
  Declares: capabilities.monitoring.coredns = { port = 9153; path = "/metrics"; }
  Reads back: config.capabilities.monitoring.coredns.labels
              → applies to metrics Service for discovery
  Uses: |> withAutoscaler for chart-internal composition (desugars to
        capabilities.autoscaling.coredns declaration)
  Writes: config.manifests (terminal — nothing reads from it)

Layer 0: kixlib (lib/default.nix)
  Resource builders: mkDeployment, mkService, mkHPA, etc. (unchanged)
  Group combinators: withAutoscaler, withPDB, withRole, mkGroup, groupToManifestList
  Serialization: mkManifest (attrset → YAML, strips _ fields)
  Options: shared option type constructors
```

## Data Flow

```
Cluster config
  │  sets service options + monitoring.enabled + monitoring.provider
  ▼
Capability interfaces (the meeting point)
  │  charts write INPUT fields (port, path, namespace)
  │  implementations write OUTPUT fields (labels, annotations)
  │  module system merges both into one attrset
  ▼
Chart resources
  │  read capability outputs (labels, controlledByAutoscaler)
  │  build K8s resources with correct metadata
  │  compose with group combinators: |> withAutoscaler |> withPDB
  │  combinators accumulate _extraConfig → capability declarations
  ▼
Implementation modules
  │  read capability declarations
  │  create cross-cutting resources (ServiceMonitor, HPA)
  │  write into config.manifests
  ▼
config.manifests (terminal — WRITE-ONLY)
  │  no module reads from here
  │  mkManifests serializes (strips _ fields, converts to YAML)
  ▼
YAML output
```

**Key invariant**: All cross-module communication goes through capability
options and the registry. `config.manifests` is the terminal sink.

## Capability Interface Design

### Monitoring (cluster-level capability)

Charts declare abstract metrics exposure. The implementation writes back
discovery metadata. Neither side knows about the other.

```nix
# modules/capabilities/monitoring.nix
options.monitoring = {
  enabled = lib.mkOption { type = types.bool; default = false; };
  provider = lib.mkOption { type = types.enum [ "prometheus" "datadog" "none" ]; };
  defaultInterval = lib.mkOption { type = types.str; default = "30s"; };
};

options.capabilities.monitoring = lib.mkOption {
  type = types.attrsOf (types.submodule {
    options = {
      # Input (charts write):
      port = lib.mkOption { type = types.int; };
      path = lib.mkOption { type = types.str; default = "/metrics"; };
      namespace = lib.mkOption { type = types.str; };
      serviceName = lib.mkOption { type = types.str; };

      # Output (implementation writes back):
      labels = lib.mkOption { type = types.attrsOf types.str; default = {}; };
      annotations = lib.mkOption { type = types.attrsOf types.str; default = {}; };
    };
  });
};
```

**What changed from current `monitoring.targets`**: The current `scrapeTargetType`
has `serviceName`, `portName`, `selector` — all Prometheus-shaped. The new
interface has `port`, `path`, `namespace`, `serviceName` (abstract) plus output
fields for bidirectional flow. No `portName`, no `selector`.

### Prometheus implementation — "find metric endpoints, not find coredns"

```nix
# modules/implementations/monitoring-prometheus.nix
config = lib.mkIf (cfg.enabled && cfg.provider == "prometheus") {
  # Write BACK to charts: generic discovery label for ALL monitored services.
  # This is "find metric endpoints" — one label, not per-service coupling.
  capabilities.monitoring = lib.mapAttrs (_: _target: {
    labels."kix.monitoring/scrape" = "true";
    annotations = {
      "kix.monitoring/port" = toString _target.port;
      "kix.monitoring/path" = _target.path;
    };
  }) targets;

  # Create ServiceMonitors matching the generic label.
  manifests = lib.mapAttrs' (name: target:
    lib.nameValuePair "monitoring-${name}-servicemonitor"
      (mkServiceMonitor { selector.matchLabels."kix.monitoring/scrape" = "true"; ... })
  ) targets;
};
```

### Datadog drop-in replacement — zero chart changes

```nix
# modules/implementations/monitoring-datadog.nix
config = lib.mkIf (cfg.enabled && cfg.provider == "datadog") {
  capabilities.monitoring = lib.mapAttrs (_name: target: {
    labels = {};  # Datadog doesn't use label selectors
    annotations = {
      "ad.datadoghq.com/check_names" = builtins.toJSON [ "openmetrics" ];
      "ad.datadoghq.com/instances" = builtins.toJSON [{
        prometheus_url = "http://%%host%%:${toString target.port}${target.path}";
      }];
    };
  }) targets;
  # No CRDs needed — Datadog Agent discovers via pod annotations.
};
```

### Chart side — CoreDNS example

```nix
# pkgs/coredns/resources.nix — extraConfig section
extraConfig = {
  # Abstract declaration: "I have metrics on port 9153."
  # The chart doesn't know about Prometheus, Datadog, or ServiceMonitors.
  capabilities.monitoring.coredns = lib.mkIf
    (hasPrometheus && cfg.prometheus.service.enabled
      && cfg.prometheus.monitor.enabled) {
    port = 9153;
    path = "/metrics";
    namespace = cfg.namespace;
    serviceName = "coredns-metrics";
  };

  registry.coredns = { /* ... unchanged ... */ };
};

# The metrics Service reads back labels from the capability output.
metricsService = kixlibCoredns.networking.mkService {
  metadata = {
    name = "coredns-metrics";
    labels = { "app.kubernetes.io/component" = "metrics"; }
      // (config.capabilities.monitoring.coredns.labels or {});
    annotations = (config.capabilities.monitoring.coredns.annotations or {});
  };
  spec.ports = [{ name = "metrics"; port = 9153; targetPort = 9153; }];
  spec.selector = selectorLabels;
};
```

## Resource Group Combinators

Combinators operate on **resource groups** (attrsets of named resources) and
return modified groups. They accumulate capability declarations in `_extraConfig`
— this is how pipes desugar to registry declarations.

### The uniform interface

```nix
# A resource group:
{
  deployment = <attrset>;      # K8s Deployment
  service = <attrset>;         # K8s Service
  _extraConfig = { ... };      # Accumulated capability declarations
}

# Every combinator: group -> group (composable via |>)
```

### Core combinators in kixlib

```nix
combinators = {
  mkGroup = resources: resources // { _extraConfig = {}; };

  groupToManifestList = prefix: group:
    lib.mapAttrsToList (k: v: { name = "${prefix}-${k}"; resource = v; enable = true; })
      (builtins.removeAttrs group ["_extraConfig"]);

  groupExtraConfig = group: group._extraConfig or {};

  # Pipe conditional: apply combinator only if condition is true
  optionalPipe = cond: f: x: if cond then f x else x;

  # withAutoscaler: removes spec.replicas + declares into autoscaling registry
  withAutoscaler = name: { minReplicas ? 1, maxReplicas, ... }: group: ...;

  # withPDB: adds PodDisruptionBudget to group (chart-internal, no registry)
  withPDB = { minAvailable ? null, maxUnavailable ? null, ... }: group: ...;

  # withRole: creates SA + Role + Binding, patches serviceAccountName on pod
  withRole = { rules, roleKind ? "ClusterRole", ... }: group: ...;
};
```

### Usage — Luca's vision realized

```nix
# In pkgs/coredns/resources.nix
workloadGroup =
  { inherit deployment; }
  |> kixlib.combinators.mkGroup
  |> kixlib.combinators.withRole {
       rules = [
         { apiGroups = [""]; resources = ["endpoints" "services" "pods" "namespaces"];
           verbs = ["list" "watch"]; }
       ];
     }
  |> kixlib.combinators.optionalPipe cfg.hpa.enabled
       (kixlib.combinators.withAutoscaler "coredns" {
         inherit (cfg.hpa) minReplicas maxReplicas;
       })
  |> kixlib.combinators.optionalPipe pdbEnabled
       (kixlib.combinators.withPDB {
         inherit (cfg.podDisruptionBudget) minAvailable;
       });

# Result group contains:
#   deployment          — serviceAccountName set, spec.replicas = null
#   serviceaccount      — created by withRole
#   clusterrole         — created by withRole
#   clusterrolebinding  — created by withRole
#   pdb                 — created by withPDB
#   _extraConfig        — { capabilities.autoscaling.coredns = { ... }; }
#   (HPA is NOT here — it's created by autoscaling-hpa.nix from the registry)
```

### Why the HPA isn't in the group

The combinator declares **intent** ("I want autoscaling with these params").
The implementation module decides **how** (HPA vs KEDA vs whatever). Switching
from HPA to KEDA requires changing one implementation module, not every chart.
This is the "pipes desugar to registries" pattern.

## Practical Limits of Composable Primitives

Analysis of the three existing charts shows that **only 20–30% of chart code is
standard deployment boilerplate** that primitives could absorb:

| Chart | Standard Pattern | RBAC | App-Specific | Cross-Cutting |
|-------|-----------------|------|-------------|--------------|
| CoreDNS (423 lines) | 13% | 5% | 59% | 12% |
| Valkey (894 lines) | 18% | 0% | 65% | 7% |
| cert-manager (593 lines) | 30% | 34% | 20% | 8% |

The dominant cost is irreducible application complexity: Corefile rendering,
sentinel/replication branching, RBAC rule definitions, webhook configurations.
Primitives and combinators compress the mechanical parts (SA+Deployment+Service
wiring, HPA creation, PDB boilerplate) but don't touch the app-specific 60–70%.

This is fine. The value isn't in reducing line count — it's in:
- **Zero coupling** between charts and cross-cutting implementations
- **Composability** via pipes for the parts that ARE standard
- **Introspection** via capability registries (`kix status`, `kix graph`)
- **Swappability** of implementations (Prometheus → Datadog, HPA → KEDA)

## Module File Structure

```
modules/
  default.nix              # manifests option + imports (MODIFY)
  registry.nix             # service registry (KEEP)
  cluster.nix              # cluster-wide settings (KEEP)
  network-policy.nix       # network policy declarations (KEEP)
  capabilities/
    monitoring.nix         # NEW — "I have metrics" interface
    autoscaling.nix        # NEW — "I want to scale" interface
  implementations/
    monitoring-prometheus.nix  # NEW — ServiceMonitor creation
    monitoring-datadog.nix     # NEW — Datadog annotation writeback
    autoscaling-hpa.nix        # NEW — HPA creation

lib/
  default.nix              # kixlib (MODIFY — add combinators section)
  options.nix              # shared option types (KEEP)

pkgs/<chart>/
  default.nix              # mkChartModule call (KEEP)
  options.nix              # chart options (KEEP)
  resources.nix            # resource construction (MODIFY)
    # Changes:
    # - extraConfig uses capabilities.monitoring.* instead of monitoring.targets.*
    # - reads back capability outputs for labels/annotations
    # - optionally uses resource group combinators

clusters/
  example.nix              # cluster config (MODIFY — monitoring. → capabilities.)
```

## Big-Bang Migration Plan

Adam chose big bang. All changes happen together in one coordinated effort.

### Step 0: Snapshot baseline
Build all 17 variants + 3 clusters, save YAML output. This is ground truth for
verifying that non-monitoring resources are byte-identical after migration.

### Step 1: Create capability interfaces
- `modules/capabilities/monitoring.nix` — abstract interface with input/output fields
- `modules/capabilities/autoscaling.nix` — for future combinator integration

### Step 2: Create implementation modules
- `modules/implementations/monitoring-prometheus.nix` — logic from current
  `monitoring.nix` + generic label writeback
- `modules/implementations/autoscaling-hpa.nix` — for future combinator integration

### Step 3: Update infrastructure
- `modules/default.nix` — new imports
- Delete `modules/monitoring.nix`

### Step 4: Update all charts
- `pkgs/coredns/resources.nix` — `monitoring.targets.*` → `capabilities.monitoring.*`,
  merge capability labels into metrics Service
- `pkgs/valkey/resources.nix` — same pattern
- `pkgs/cert-manager/resources.nix` — same pattern (3 targets)

### Step 5: Add combinators to kixlib
- `lib/default.nix` — add `combinators` section (mkGroup, withAutoscaler,
  withPDB, withRole, optionalPipe, groupToManifestList)

### Step 6: Update cluster configs
- `clusters/example.nix` — `monitoring.*` → cluster-level monitoring config
- Other cluster configs as needed

### Step 7: Update tests
- `flake.nix` — rewrite all monitoring assertions to use `capabilities.monitoring.*`
- Add new assertions for capability writeback (labels exist on Services)

### Step 8: Regenerate golden files
- `./scripts/update-golden.sh`
- Diff: only ServiceMonitor resources and metrics Services should change

### Step 9: Verify
- Diff all variants against Step 0 baseline
- `nix flake check` — all checks pass
- Manual inspection of representative ServiceMonitor

### Risk Areas

1. **Bidirectional writeback infinite recursion** (HIGH) — Implementation reads
   `capabilities.monitoring` to write BACK to `capabilities.monitoring`. Mitigate
   by using `lib.mkDefault` or separating input/output into distinct sub-paths.

2. **Option namespace collision** (MEDIUM) — `capabilities.monitoring.enabled`
   looks like a target named "enabled" if the option is `attrsOf submodule`.
   Solution: cluster-level switches live under `monitoring.*` (separate from
   `capabilities.monitoring.*` which is `attrsOf` targets).

3. **Golden file diff larger than expected** (MEDIUM) — Label writeback changes
   Service resources beyond just ServiceMonitors. Mitigate by reviewing diff
   carefully; non-monitoring resources must be unchanged.

4. **mkChartModule extraConfig type** (LOW) — `extraConfig` is currently untyped.
   Adding `capabilities.*` paths works because the module system already declares
   those options. No mkChartModule changes needed.

## What This Gets Us

1. **Zero coupling** — Swap Prometheus for Datadog without touching chart code.
2. **Terminal manifests** — `config.manifests` is write-only. All communication
   through typed capability options.
3. **Pipe composition** — `|> withAutoscaler |> withPDB |> withRole` for charts.
   Desugars to capability registry declarations.
4. **Generic monitoring** — "Find metric endpoints", not "find coredns".
   One discovery label for all monitored services.
5. **Introspection** — Capability registries enable `kix status`, `kix graph`,
   `kix validate` without understanding individual charts.
6. **Dependency DAG** — Capability declarations + structural inference give Luca
   his DAG across all 5 use cases.
7. **RFC 189 compatible** — Capability interfaces are structurally compatible
   with NixOS Contracts if/when that RFC lands.

## Open Questions (Post-Migration)

| # | Question | Status |
|---|----------|--------|
| 1 | Attrsets vs derivations + ref interface | Revisit after capability migration proves the pattern |
| 2 | Registry as capability (computed FQDNs) | Deferred — revisit after migration |
| 3 | Chart isolation (current vs submodules) | Re-evaluate once capabilities show how much decoupling they provide |
| 4 | `perCluster` evaluation (like flake-parts `perSystem`) | Orthogonal — explore independently |
| 5 | Contract compliance testing (RFC 189 behavioral tests) | Worth adding after interfaces stabilize |
