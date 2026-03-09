# 07: The Proposed Architecture

## Layer Diagram

```
Layer 3: Cluster config (clusters/example.nix)
  Sets: services.coredns.enable = true
        capabilities.autoscaling.coredns = { min = 2; max = 10; }
        monitoring = { enabled = true; provider = "prometheus"; }

Layer 2: Capability modules
  Interface:  modules/capabilities/monitoring.nix
              modules/capabilities/autoscaling.nix
              modules/capabilities/network-policy.nix
  Implementation: modules/implementations/monitoring-prometheus.nix
                  modules/implementations/autoscaling-hpa.nix
  Bidirectional: reads chart declarations, writes back labels/annotations

Layer 1: Chart modules (pkgs/*/resources.nix)
  Uses: |> withAutoscaler for chart-intrinsic behavior
  Declares: capabilities.monitoring.coredns = { port = 9153; }
  Reads back: config.capabilities.monitoring.coredns.labels
  Exports: services.<name>._exports = { deployment = { name, namespace, labels }; }
  Writes: config.manifests (terminal output — nothing reads from it)

Layer 0: kixlib (lib/default.nix)
  Resource builders: mkDeployment, mkService, mkHPA, etc.
  Group combinators: withAutoscaler, withPDB, groupToManifestList
  Serialization: mkManifest (attrset → YAML, strips _ fields)
```

## Data Flow

```
Cluster config
  ↓ sets chart options + capability declarations
Capability interfaces (abstract meeting point)
  ↓ implementations read declarations
  ↓ implementations write back labels/annotations to capabilities
  ↓ implementations create their own manifests (ServiceMonitor, HPA, etc.)
Chart resources
  ↓ read capability outputs (labels, controlledByAutoscaler, etc.)
  ↓ build K8s resources with correct metadata
  ↓ optionally compose with group combinators (|> withAutoscaler)
config.manifests (terminal — nothing reads from this)
  ↓ mkManifests serializes (strips _ fields, converts to YAML)
YAML output
```

**Key invariant**: `config.manifests` is write-only. No module reads from it.
All cross-module communication goes through options (capabilities, registry,
chart exports).

## What Changes from Current Architecture

### Current

```nix
# coredns resources.nix — extraConfig
monitoring.targets.coredns = {
  serviceName = "coredns-metrics";    # K8s-level detail
  portName = "metrics";               # K8s-level detail
  selector = selectorLabels // { ... }; # K8s-level detail
};
```

```nix
# monitoring.nix — reads targets, creates ServiceMonitors
config.manifests = lib.mapAttrs' (name: target:
  # knows about ServiceMonitor structure, K8s selectors
  mkServiceMonitor { selector.matchLabels = target.selector; ... }
) cfg.targets;
```

### Proposed

```nix
# coredns resources.nix — extraConfig
capabilities.monitoring.coredns = {
  port = 9153;      # abstract — what port has metrics
  path = "/metrics"; # abstract — what path to scrape
};
```

```nix
# monitoring-prometheus.nix — reads capabilities, writes back, creates resources
# Writes back to charts:
capabilities.monitoring = lib.mapAttrs (name: target: {
  labels."kix.monitoring/scrape" = "true";
}) targets;

# Creates ServiceMonitors (charts don't know about this):
config.manifests = lib.mapAttrs' (name: target:
  mkServiceMonitor { ... }
) targets;
```

```nix
# coredns resources.nix — reads back from capability
metricsService = kixlibCoredns.networking.mkService {
  metadata.labels = { ... } // (config.capabilities.monitoring.coredns.labels or {});
  ...
};
```

## Module File Structure

```
modules/
  default.nix          # manifests option (keep existing)
  registry.nix         # service registry (keep existing)
  cluster.nix          # cluster-wide settings (keep existing)
  capabilities/
    monitoring.nix     # interface: "I have metrics"
    autoscaling.nix    # interface: "I want to scale"
    network-policy.nix # interface: "I need network rules"
  implementations/
    monitoring-prometheus.nix   # ServiceMonitor creation
    autoscaling-hpa.nix         # HPA creation
    network-policy-k8s.nix      # NetworkPolicy creation

lib/
  default.nix          # kixlib (add combinators section)
    combinators = {
      withAutoscaler = ...;
      withPDB = ...;
      groupToManifestList = ...;
    };

pkgs/<chart>/
  default.nix          # mkChartModule (unchanged)
  options.nix          # chart options (unchanged)
  resources.nix        # resource construction
    # Changes:
    # - extraConfig uses capabilities.* instead of monitoring.targets.*
    # - reads back capability outputs for labels/annotations
    # - optionally uses resource group combinators
```

## Migration Path

### Phase A: Capability interfaces (monitoring first)

1. Create `modules/capabilities/monitoring.nix` (the abstract interface)
2. Create `modules/implementations/monitoring-prometheus.nix` (moves logic from
   current `modules/monitoring.nix`)
3. Update chart extraConfig sections: `monitoring.targets.*` → `capabilities.monitoring.*`
4. Charts read back `config.capabilities.monitoring.*.labels` for service metadata
5. Remove old `modules/monitoring.nix`
6. Update tests/golden files

This is the highest-value change. It demonstrates the pattern and fixes the
tight coupling Luca identified.

### Phase B: Resource group combinators

1. Add `combinators` to kixlib
2. Optionally refactor chart resources.nix to use groups where they simplify code
3. This is ergonomic sugar, not architectural — can happen anytime

### Phase C: Autoscaling capability

1. Create `modules/capabilities/autoscaling.nix`
2. Create `modules/implementations/autoscaling-hpa.nix`
3. Charts that currently build HPAs inline can optionally move to capability
   declarations
4. Charts read `controlledByAutoscaler` to decide about `spec.replicas`

### Phase D: Evaluate submodule isolation

After A-C, evaluate whether `types.submoduleWith` per chart adds value.
The capability interfaces may provide enough decoupling that formal isolation
isn't needed. Decide based on experience.

## What This Gets Us

1. **Zero coupling between charts and implementations.** Swap Prometheus for
   Datadog without changing chart code.

2. **`config.manifests` as terminal output.** No cross-module reads from
   manifests. All communication through typed options.

3. **`|> withAutoscaler` for chart authors.** Resource group combinators for
   composable chart-internal behavior.

4. **Cluster-level cross-cutting concerns.** Capability declarations for
   operational concerns added from outside charts.

5. **Dependency tracking becomes simpler.** Once cross-module communication
   is through capabilities (not manifest inspection), dependencies are
   implicit in the capability graph. Structural inference covers K8s-intrinsic
   references.

6. **validateManifestSet becomes optional.** Structural correctness comes from
   the capability interfaces and the module system's type checking. Cross-resource
   validation is a safety net, not the primary correctness mechanism.
