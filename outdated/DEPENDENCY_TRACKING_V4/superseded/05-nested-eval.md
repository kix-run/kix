# 05: Nested evalModules and the Pragmatic Path

## Luca's Proposal

> Module systems can be evaluated multiple times. So you could have coredns have
> its own module system where the manifest IS the derivation AND the config
> (output = config.toYaml). And then have a higher level module system that
> interacts on this higher level of abstraction and sets inputs on the coredns
> evaluation (like values.yaml).

Two evaluation levels:

1. **Inner (per-chart)**: Like Helm. Worries about the individual package.
   Each chart has its own `evalModules`. Output = manifests.
2. **Outer (cluster)**: Like Argo. Worries about services and interactions.
   Sets inputs on inner evaluations. Handles cross-cutting concerns.

## How NixOS Does This

### NixOS Containers

The canonical example of nested `evalModules`. Each container gets its own
complete NixOS evaluation:

```nix
containers.<name>.config = { ... };

# Each container runs its own evalModules.
# Key property: ONE-DIRECTIONAL data flow.
# Host passes config INTO container, but container's output
# does NOT flow back into host's module system.
containerConfig = (evalModules {
  modules = [ containerCfg.config ];
}).config;

# Host reads container output as a COMPUTED VALUE,
# not as a module option. Host generates its own resources
# (veth interfaces, firewall rules) from the output.
```

### flake-parts `perSystem`

Two-level evaluation: outer (flake-level) and inner (per-system):

```nix
# perSystem modules can read top-level config (via specialArgs)
# but CANNOT write to top-level options.
# Data flows down, results flow up as computed values.
```

### The Pattern

```
Outer evalModules
  ├── reads outer config
  ├── passes values DOWN into inner evalModules
  ├── inner evalModules produces its own config
  ├── outer reads inner config as COMPUTED VALUE
  └── outer generates its own resources from inner output
```

## Options for kixpkgs

### Option A: True nested evalModules (per-chart)

Each chart gets its own `evalModules`. The cluster-level module system
instantiates chart evaluations:

```nix
mkCluster = { charts }: let
  # Each chart evaluated independently
  chartEvals = lib.mapAttrs (name: def:
    lib.evalModules {
      modules = [ def.module { config = def.values; } ];
      specialArgs = { inherit pkgs lib kixlib; };
    }
  ) charts;

  # Cluster-level evaluation for cross-cutting concerns
  clusterEval = lib.evalModules {
    modules = [
      ./modules/cluster.nix
      ./modules/capabilities/monitoring.nix
      ./modules/implementations/monitoring-prometheus.nix
      ({ config, ... }: {
        # Inject chart exports as read-only data
        config.chartExports = lib.mapAttrs
          (_: eval: eval.config.exports or {}) chartEvals;

        # Collect all inner manifests into outer manifests
        config.manifests = lib.mkMerge
          (map (eval: eval.config.manifests) (lib.attrValues chartEvals));
      })
    ];
  };
in clusterEval;
```

**Pros**:
- True hermetic isolation. Chart A cannot read chart B's options.
- Clear "values.yaml" API boundary.
- Independent testability (already have this with `mkChartManifests`).

**Cons**:
- Cross-cutting modules can't participate in inner evaluations. A monitoring
  capability can't write labels back into a chart's pod template (the inner
  eval is already done).
- Two separate evaluation systems to understand and maintain.
- Threading data between levels requires explicit plumbing (exports,
  chartExports, computed values).
- The `|> withAutoscaler` brain-breaker gets HARDER — the HPA needs inner
  eval data, but if it's an outer concern, it can't be injected into the
  inner eval.

### Option B: types.submoduleWith per chart (recommended pragmatic path)

Instead of separate `evalModules`, use `types.submoduleWith` to give each
chart its own namespace within a single evaluation:

```nix
# modules/charts.nix
options.charts = lib.mkOption {
  type = lib.types.attrsOf (lib.types.submoduleWith {
    modules = [ chartBaseModule ];
    specialArgs = { inherit kixlib; };
  });
};

chartBaseModule = { config, name, ... }: {
  options = {
    module = lib.mkOption { type = lib.types.path; };
    values = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
    manifests = lib.mkOption { type = manifestsType; default = {}; };
    exports = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
  };
};
```

**Pros**:
- Same isolation boundary as nested evalModules (charts can't see each
  other's internal state).
- Participates in the same module merge system — cross-cutting modules CAN
  read `config.charts.*.exports` and write to top-level `config.manifests`.
- The bidirectional capability flow (03-inversion-of-control.md) works
  naturally — both the chart submodule and the implementation module
  participate in the same fixpoint.
- Migration from current design is incremental (move `services.<name>` into
  `charts.<name>`).
- If true evalModules isolation is ever needed, submodule → nested evalModules
  is a mechanical migration (same API boundary).

**Cons**:
- Not fully hermetic — a chart COULD theoretically read another chart's
  submodule (though this would require explicitly accessing
  `config.charts.other.*` which is visible and reviewable).
- Doesn't give you native `exportReferencesGraph` (still attrsets, not
  derivations).

### Option C: Hybrid — submodules with mixin injection

Charts are submodules, but the outer level can inject modules INTO the inner
evaluation before it runs:

```nix
charts.coredns = {
  module = ./pkgs/coredns;
  mixins = [
    (autoscaling { min = 2; max = 10; target = "deployment"; })
  ];
  values.replicaCount = 3;
};
```

The mixin runs INSIDE the chart's submodule, so it has access to the chart's
deployment, labels, namespace. This is the `|> withAutoscaler` pattern
expressed as module composition.

**Pros**:
- Solves the brain-breaker — mixins can touch inner resources.
- Clean outer API — cluster operator adds a mixin, doesn't modify chart code.

**Cons**:
- Mixins can't access other charts (they run inside one chart's submodule).
  Cross-chart concerns must live at the outer level.
- Ordering of mixins matters if they conflict (two mixins both setting replicas).

### Option D: Keep current flat design, improve abstractions

Don't add nesting. Instead, improve the current flat module system by:
- Converting monitoring.targets to capability interfaces (03-inversion-of-control.md)
- Adding resource group combinators (04-with-autoscaler.md)
- Making `config.manifests` terminal output (01-manifests-from-config.md)

**Pros**:
- Least disruption. 42 existing checks still pass.
- mkChartModule already provides most of the per-chart namespacing.
- The capability interface handles cross-cutting concerns without nesting.

**Cons**:
- No formal isolation between charts. Convention only.
- Doesn't match Luca's mental model of inner/outer evaluation.

## Recommendation

**Option D now, with Option B as the next evolution.**

The current flat design with mkChartModule already provides per-chart
namespacing (`services.<name>`, manifest names prefixed with chart name).
The capability interface (03-inversion-of-control.md) handles cross-cutting
concerns. Resource group combinators (04-with-autoscaler.md) handle
chart-internal composition.

These changes can be made incrementally without restructuring the module
system. Once they're in place, moving to Option B (submodules per chart) is
a clean migration:

1. `services.<name>` options → `charts.<name>.values`
2. `mkChartModule` → chart submodule base module
3. `extraConfig` → capability declarations (already migrated)
4. `config.manifests` → `config.charts.<name>.manifests` (collected at outer level)

The migration is mechanical because the API boundary (what a chart declares,
what it exports) doesn't change.

## What About Inner Derivations + Outer Attrsets?

Luca's deeper point — "the manifest IS the derivation AND the config
(output = config.toYaml)" — suggests that inner evaluations could produce
derivations (getting native Nix dependency tracking), while the outer level
works with attrsets (for capability interfaces and cross-cutting modules).

This hybrid is theoretically possible:

```nix
# Inner eval: output is derivations
innerManifests = lib.mapAttrs (name: resource:
  kixlib.mkManifest resource  # attrset → derivation
) innerEval.config.manifests;

# Outer eval: works with attrsets for capabilities
# Then converts to derivations at the output boundary
```

But it loses the ability for outer modules to modify inner resources (a
derivation is frozen). If the outer level only ADDS resources (HPAs,
ServiceMonitors) and never modifies inner ones, this works. And with
capabilities writing labels/annotations BACK into the inner eval via the
bidirectional flow, the inner eval's resources would already have the right
metadata before being frozen into derivations.

This is worth exploring but is a larger architectural change. The capability
interface work should come first — it clarifies what data flows between
levels, which makes the nested eval design cleaner.
