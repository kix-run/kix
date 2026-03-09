# 02: The `_type` Pattern and Extensibility

## Luca's Observation

> The default nix only understands dependencies as store paths — due to it
> originally being a build system. However, it has some kind of support for
> those underscore entries inside the attrsets. If you look at the actual
> implementation of mkOption, all it does is set some _field things on the
> attr set, that some other evaluator knows how to understand.

This is correct. The NixOS module system uses `_type`-tagged attrsets as its
core mechanism. Building dependency tracking metadata this way is not "a fully
stupid idea" — it's how the module system itself works internally.

## How `_type` Works in the Module System

The module system defines several functions that return tagged attrsets:

```nix
mkOverride = priority: content: { _type = "override"; inherit priority content; };
mkIf = condition: content: { _type = "if"; inherit condition content; };
mkMerge = contents: { _type = "merge"; inherit contents; };
mkOption = attrs: attrs // { _type = "option"; };
```

During evaluation, `dischargeProperties` in `lib/modules.nix` pattern-matches
on `_type` to unwrap these:

```nix
dischargeProperties = def:
  if def._type or "" == "merge" then
    concatMap dischargeProperties def.contents
  else if def._type or "" == "if" then
    if def.condition then dischargeProperties def.content else []
  else if def._type or "" == "override" then
    [{ inherit (def) priority; value = def.content; }]
  else
    [{ priority = defaultPriority; value = def; }];  # ← unknown _type passes through
```

Key: **unknown `_type` values pass through as normal values.** The module system
does not strip them.

## What Survives the Module System

Custom underscore-prefixed fields on attrsets survive at every stage:

| Stage | Survives? | Notes |
|---|---|---|
| `dischargeProperties` | Yes | Only checks `_type`, ignores other `_` fields |
| Type checking (`type.check`) | Yes | `isAttrs` returns true regardless of `_` fields |
| `types.anything` merge | Yes | Passes through, recursive merge preserves them |
| `types.attrsOf` merge | **Treated as data** | `_deps` becomes a key like any other |
| `types.submodule` merge | **Error** | Undeclared options cause eval failure |
| Serialization boundary | Yes | You strip them in `mkManifests` |

## What This Means for kixpkgs

Since `config.manifests` currently uses a collision-detecting type based on
`types.attrsOf` (in `modules/default.nix`), individual resource attrsets can
carry `_`-prefixed metadata:

```nix
config.manifests."coredns-deployment" = (kixlib.workload.mkDeployment { ... }) // {
  _deps = [ "coredns-configmap" "coredns-serviceaccount" ];
  _capabilities = { monitoring = true; autoscaling = false; };
};
```

These fields survive the module system and reach `mkManifests` in `flake.nix`,
where they can be:
1. Read — to build a dependency graph
2. Stripped — before serialization to YAML

## Options for Using Underscore Metadata

### Option A: `_deps` per resource (simple dependency list)

```nix
config.manifests."coredns-deployment" = deployment // {
  _deps = [ "coredns-configmap" "coredns-serviceaccount" ];
};
```

**Pros**: Simple. Charts declare what they depend on. mkManifests strips it.
**Cons**: Two sources of truth (the dependency exists in both the reference AND
the `_deps` list). Can get stale if resources are renamed. Same problem as the
rejected `_deps` approach from V1.

### Option B: `_type`-style wrappers (like mkIf/mkOverride)

Define custom wrappers that the serialization boundary understands:

```nix
kixlib.mkRef = name: value: { _type = "kix-ref"; inherit name value; };
# Usage:
roleRef.name = kixlib.mkRef "coredns-clusterrole" clusterRole.metadata.name;
```

**Pros**: Dependency is captured AT the reference site, not separately.
**Cons**: `dischargeProperties` passes this through as a plain value (unknown
`_type`), so the field value becomes `{ _type = "kix-ref"; name = ...; value = ...; }`
instead of just the string. Type checking on the containing option would fail
unless it uses `types.anything`. This fights the module system.

### Option C: Parallel dependency option (not inline)

Declare a separate `config.dependencies` option alongside `config.manifests`:

```nix
options.dependencies = mkOption {
  type = types.attrsOf (types.listOf types.str);
  default = {};
};
# Usage:
config.dependencies."coredns-deployment" = [ "coredns-configmap" ];
config.manifests."coredns-deployment" = deployment;
```

**Pros**: Clean separation. Works with the module system naturally. Multiple
modules can contribute dependencies (via list merging).
**Cons**: Two places to maintain. Easy to forget to add dependencies.

### Option D: Don't track dependencies via metadata — use capabilities instead

If the capability architecture (see `03-inversion-of-control.md`) handles all
cross-module communication through options, and `config.manifests` becomes
terminal output, then dependency tracking via metadata may be unnecessary.

Dependencies would be implicit in the capability declarations: if coredns
declares `capabilities.monitoring.coredns`, there is an implicit dependency
between the ServiceMonitor (created by the monitoring implementation) and
coredns's resources. The apply-ordering tool would derive this from the
capability graph, not from manifest metadata.

**Pros**: No extra metadata. Dependencies are structural.
**Cons**: Only covers capability-based dependencies. Doesn't cover
K8s-intrinsic dependencies (ServiceAccount → RoleBinding, ConfigMap → Deployment volume).

### Option E: Layered — capabilities for cross-chart, inference for intra-chart

Combine Option D (capabilities for cross-chart dependencies) with structural
inference (walking well-known K8s reference fields like `serviceAccountName`,
`roleRef`, `configMap` volumes) for intra-chart dependencies. This was the
"Layer 1" from V3.

**Pros**: Covers both cases. No manual metadata needed.
**Cons**: Structural inference is brittle for CRDs (Luca's feedback on V2).

## Recommendation

**Option E (layered)** is the most complete. Option D alone misses K8s-intrinsic
dependencies. Option A/B/C all have the "two sources of truth" problem.

However, the MOST IMPORTANT finding is that underscore-prefixed metadata IS
safe to use in kixpkgs's current type system. If we decide to add `_deps` or
any other metadata to resources, the module system will not strip or error on
it. This gives us a safe escape hatch for future needs without committing to a
specific dependency tracking strategy now.

For the immediate architectural work, the capability system (Option D) should
be the priority. Dependency tracking via metadata is a follow-on concern that
becomes simpler once the architecture is right.
