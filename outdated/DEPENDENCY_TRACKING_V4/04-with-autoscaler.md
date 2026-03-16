# 04: Solving the `withAutoscaler` Brain-Breaker

## The Problem

Luca wants to write:

```nix
corednsDeployment |> withAutoscaler
```

This is hard because `withAutoscaler` is a one-to-many transformation: one
Deployment in, Deployment + HPA out. The Nix pipe operator (`|>`) passes one
value. Where do the extra resources go?

Additionally, if there are two evaluation levels (inner chart, outer cluster),
the HPA needs information from the inner level (Deployment name, labels,
apiVersion) but might be an outer-level concern (operational autoscaling added
by a cluster operator, not baked into the chart).

## Approaches Analyzed

### Approach 1: Resource Combinators (pure functions)

```nix
withAutoscaler = { minReplicas, maxReplicas, ... }: deployment:
  {
    deployment = deployment // { spec = deployment.spec // { replicas = null; }; };
    hpa = kixlib.autoscaling.mkHorizontalPodAutoscaler {
      scaleTargetRef = {
        apiVersion = deployment.apiVersion;
        kind = deployment.kind;
        name = deployment.metadata.name;
      };
      inherit minReplicas maxReplicas;
    };
  };
```

**Problem**: Returns an attrset, not a single resource. The caller must
destructure and wire both into `manifestList`. Composition breaks:

```nix
deployment
|> withAutoscaler { ... }   # returns { deployment, hpa }
|> withPDB { ... }          # expects a deployment, gets { deployment, hpa } — type mismatch
```

**Verdict**: Doesn't compose. The one-to-many return type poisons the pipeline.

### Approach 2: Resource Groups (recommended for chart-internal use)

A "resource group" is just an attrset of named resources. ALL combinators
operate on groups:

```nix
# A resource group is { deployment = <resource>; service = <resource>; ... }
withAutoscaler = { minReplicas, maxReplicas, target ? "deployment" }:
  group:
  let dep = group.${target}; in
  group // {
    ${target} = dep // { spec = dep.spec // { replicas = null; }; };
    hpa = kixlib.autoscaling.mkHorizontalPodAutoscaler {
      scaleTargetRef = {
        apiVersion = dep.apiVersion;
        kind = dep.kind;
        name = dep.metadata.name;
      };
      inherit minReplicas maxReplicas;
    };
  };

withPDB = { minAvailable ? null, maxUnavailable ? null, target ? "deployment" }:
  group:
  let dep = group.${target}; in
  group // {
    pdb = kixlib.policy.mkPodDisruptionBudget {
      selector.matchLabels = dep.spec.selector.matchLabels;
      inherit minAvailable maxUnavailable;
    };
  };
```

**Composition works naturally:**

```nix
{ inherit deployment; }
|> withAutoscaler { minReplicas = 2; maxReplicas = 10; }
|> withPDB { minAvailable = 1; }
# Result: { deployment (replicas=null), hpa, pdb }
```

Every combinator takes a group, returns a group. The one-to-many problem
dissolves because the GROUP is the unit of composition, not individual resources.

**Usage in a chart's resources.nix:**

```nix
# Current coredns code has deployment, hpa, pdb as separate let-bindings
# with conditional enable flags. With resource groups:

workloadGroup = { inherit deployment; }
  |> lib.optionalPipe cfg.hpa.enabled (kixlib.combinators.withAutoscaler {
    inherit (cfg.hpa) minReplicas maxReplicas metrics;
  })
  |> lib.optionalPipe pdbEnabled (kixlib.combinators.withPDB {
    inherit (cfg.podDisruptionBudget) minAvailable maxUnavailable;
  });

# Convert group to manifestList:
manifestList =
  (kixlib.combinators.groupToManifestList "coredns" workloadGroup)
  ++ [
    { name = "coredns-configmap"; resource = coreDnsConfigMap; enable = true; }
    { name = "coredns-service"; resource = service; enable = true; }
    ...
  ];
```

Where `groupToManifestList` flattens the group:

```nix
groupToManifestList = prefix: group:
  lib.mapAttrsToList (k: v: {
    name = "${prefix}-${k}";
    resource = v;
    enable = true;
  }) group;
```

**Pros**: Clean composition. Pure functions on attrsets. No module system
interaction needed. Works at eval time. Cross-resource references are natural
(combinators read from the group directly).

**Cons**: Only works inside the chart definition. An outer module can't inject
a combinator into the middle of the pipeline. Inner-level only.

### Approach 3: Aspect/Mixin Pattern

```nix
mkChartModule {
  name = "coredns";
  aspects = [ (autoscaling { min = 2; max = 10; }) monitoring ];
  ...
};
```

Aspects are functions applied to the chart evaluation, adding resources and
patching existing ones.

**Verdict**: Reinvents the module system poorly. Aspects can't reference each
other's outputs. If they need to read final resource state, you need a fixpoint
over aspect application — which IS the module system. Don't reinvent it.

### Approach 4: Module System Options (for cluster-level composition)

Expose resources as options that cross-cutting modules can read:

```nix
# Chart exposes metadata via a non-manifest option:
config.services.coredns._exports.deployment = {
  name = "coredns";
  namespace = cfg.namespace;
  apiVersion = "apps/v1";
  kind = "Deployment";
  labels = allLabels;
  selectorLabels = selectorLabels;
};

# Cross-cutting autoscaling module reads exports, writes manifests:
config.manifests."autoscaling-coredns-hpa" = lib.mkIf
  (config.capabilities.autoscaling ? coredns)
  (kixlib.autoscaling.mkHorizontalPodAutoscaler {
    scaleTargetRef = {
      inherit (config.services.coredns._exports.deployment)
        apiVersion kind name;
    };
    inherit (config.capabilities.autoscaling.coredns)
      minReplicas maxReplicas metrics;
  });
```

**Critical**: The exports option (`_exports`) MUST be separate from `manifests`
to avoid circular evaluation. If the autoscaling module reads
`config.manifests."coredns-deployment"` to create
`config.manifests."coredns-hpa"`, that's a cycle in the fixpoint.

**Pros**: Full module system composition. Outer modules can add autoscaling
without changing charts. Works with capability interfaces. No cycle (exports
and manifests are separate option trees).

**Cons**: Charts must export metadata in addition to writing manifests.
Slight boilerplate.

### Approach 5: Builder Pattern

```nix
mkWorkload {
  name = "coredns";
  deployment = { ... };
  autoscaling = { enabled = true; min = 2; max = 10; };
  pdb = { minAvailable = 1; };
}
```

Declare everything upfront, builder figures out resources.

**Verdict**: Good for batteries-included UX. Bad for outer-level composition
(builder was already called, can't add autoscaling after the fact). This is
basically Approach 2 with a fixed API surface.

### Approach 6: Submodule-based (Approach D from nested eval research)

Each chart lives in a `types.submoduleWith` under `config.charts.<name>`:

```nix
options.charts = lib.mkOption {
  type = types.attrsOf (types.submoduleWith {
    modules = [ chartBaseModule ];
  });
};
```

Charts have isolated `manifests` and `exports` namespaces. Cross-cutting
modules read `config.charts.coredns.exports` and write to top-level
`config.manifests`.

See `05-nested-eval.md` for details.

## The Recommended Hybrid: Approach 2 + Capability Interfaces

The key insight: **resource groups and capability interfaces serve different
needs and complement each other.**

| Need | Solution |
|---|---|
| Chart-internal composition | Resource group combinators (`\|> withAutoscaler`) |
| Cluster-level cross-cutting | Capability interfaces (`capabilities.autoscaling.coredns`) |

### Chart-internal: Resource groups for intrinsic behavior

When autoscaling is part of the chart's design (like CoreDNS's
cluster-proportional autoscaler), use resource groups:

```nix
# In pkgs/coredns/resources.nix
workloadGroup = { inherit deployment; }
  |> lib.optionalPipe cfg.hpa.enabled (kixlib.combinators.withAutoscaler {
    inherit (cfg.hpa) minReplicas maxReplicas metrics;
  });
```

This is a chart author's tool. It's the `|> withAutoscaler` syntax Luca asked
about. Clean, composable, no module system overhead.

### Cluster-level: Capabilities for operational concerns

When autoscaling is an operational decision made at the cluster level (not
baked into the chart), use the capability interface:

```nix
# In clusters/production.nix
capabilities.autoscaling.coredns = {
  minReplicas = 2;
  maxReplicas = 20;
  metrics = [{ type = "cpu"; target = 80; }];
};

# The autoscaling-hpa implementation module creates the HPA
# and sets controlledByAutoscaler = true on the capability,
# which the chart reads to drop spec.replicas
```

This is a cluster operator's tool. The chart doesn't know about it. The
autoscaling implementation creates the HPA resource.

### Why both?

Because the question "who decides about autoscaling?" has two valid answers:

1. **The chart author** — CoreDNS's cluster-proportional autoscaler is
   intrinsic to the chart. It's always part of CoreDNS when enabled. Use
   resource groups.

2. **The cluster operator** — "I want all my Deployments to have HPAs in
   production" is an operational concern. Charts shouldn't hardcode it. Use
   capability interfaces.

These aren't competing — they handle different layers of the same stack.

## Implementation Plan

### Phase 1: Resource group combinators in kixlib

Add to `lib/default.nix`:

```nix
combinators = {
  withAutoscaler = { ... }: group: ...;
  withPDB = { ... }: group: ...;
  groupToManifestList = prefix: group: ...;
};
```

Helper in `lib/`:

```nix
# lib.optionalPipe — apply a function only if condition is true
optionalPipe = cond: f: x: if cond then f x else x;
```

### Phase 2: Migrate chart-internal composition

Convert coredns's separate `hpa` and `pdb` let-bindings to use resource groups
where it simplifies the code. This is optional — the current approach also works.

### Phase 3: Capability interfaces

Add `modules/capabilities/autoscaling.nix` and
`modules/implementations/autoscaling-hpa.nix`. Charts declare
`capabilities.autoscaling.*`, implementations create HPAs.

Charts read `controlledByAutoscaler` to decide whether to set `replicas`.
