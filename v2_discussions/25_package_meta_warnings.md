# 25 — Package Meta System, Warnings & Assertions

## Status: RFC

## Problem

The kix package system lacks structured metadata for expressing compatibility
constraints, deprecations, and package-declared diagnostics. Current state:

- `meta` is an untyped attrset — only `scope` is enforced (cross-namespace
  check), `lifecycle` and `description` exist on PVC but aren't consumed
- Validation is ad-hoc: immich does `builtins.trace` for undersized PVCs
  and `throw` for missing pgvecto.rs; n8n throws on missing config
- No way to declare k8s version constraints, dependency version constraints,
  package conflicts, or deprecations
- No structured warning/assertion collection — diagnostics are invisible to
  tooling (buried in trace output or causing hard failures)
- Aliases are cluster-defined only — packages can't declare default aliases
  for the capabilities they provide (roadmap line 25)

## Design

### 1. Structured `meta`

Packages declare `meta` alongside `options` and `build`. All fields are
optional — packages that don't care about metadata don't need to touch it.

```nix
{
  meta = {
    # -- Existing fields (unchanged) --
    description = "Immich — self-hosted photo management";
    scope = "namespace";       # "namespace" | "cluster" (default: "cluster")
    lifecycle = "stateful";    # "stateful" | "stateless" (default: "stateless")

    # -- Compatibility constraints (new) --
    k8s = {
      minVersion = "1.28";     # null = no lower bound
      maxVersion = null;       # null = no upper bound
    };

    # Dependency version constraints, keyed by dep arg name.
    # Checked against the resolved dependency's `version` field
    # (from instance config) or `out.version` (from package output).
    compatibleWith = {
      postgres = {
        minVersion = "15";
        maxVersion = null;
        reason = "immich requires pgvecto.rs which needs PG15+";
      };
    };

    # Packages that cannot coexist with this one in the same resolution scope.
    # Default scope is same-namespace; cluster-wide conflicts use the
    # "cluster:" prefix.
    conflictsWith = [
      "redis"            # same-namespace conflict (valkey vs redis)
      # "cluster:traefik"  # cluster-wide conflict (hypothetical)
    ];

    # -- Capability advertisement (new) --
    # Tags describing what this package provides. Used for future
    # auto-resolution ("I need something that provides 'metrics'").
    provides = [ "photo-management" "media-server" ];

    # Default aliases — registered automatically in the resolution index
    # unless the cluster definition overrides them. Replaces the need for
    # clusters to manually set aliases for well-known capabilities.
    defaultAliases = [ "photos" ];

    # -- Deprecation (new) --
    deprecated = {
      message = "redis is superseded by valkey in kix";
      replacement = "valkey";  # optional: package name to migrate to
      deadline = "2025-06-01"; # optional: after this date, becomes an error
    };
    # Set to `null` (default) when not deprecated.
  };
}
```

**Non-goals for meta:** meta is static package-level metadata. It does not
have access to `config` or resolved dependencies — those are available in
`assertions` and `warnings` (below).

### 2. Package-declared warnings and assertions

Packages return optional `warnings` and `assertions` fields. These are
**functions** that receive the evaluated context and return diagnostic lists.

```nix
{
  meta = { ... };
  options = { ... };
  build = ...;

  # Assertions: failed = hard error (build stops)
  assertions = { config, self, deps }:
    [
      {
        assertion = builtins.elem "vectors" (deps.postgres.out.extensionNames or []);
        message = "immich requires pgvecto.rs extension on postgres";
        # Optional: when will this fail?
        failurePhase = "runtime";  # "build" (default) | "deploy" | "runtime"
      }
    ];

  # Warnings: always emitted, never fatal
  warnings = { config, self, deps }:
    let
      storageSizeGi = ...; # parse from storage.out.size
    in
    lib.optional (storageSizeGi != null && storageSizeGi < 50)
      "immich: library storage is ${storage.out.size} — recommended minimum is 50Gi";
}
```

**`assertions`** take the same shape as NixOS assertions:
`[ { assertion = bool; message = string; } ]`. Failed assertions are
collected and reported together (not one-at-a-time throws).

**`warnings`** are a list of strings. Always emitted via `builtins.trace`,
also collected on the cluster output for tooling.

**`failurePhase`** on assertions encodes the compatibility matrix concept
from the roadmap — "four distinct failure phases: build, deploy, health,
application". This tells the operator *when* a misconfiguration will
actually bite:

- `"build"` — the manifests themselves are wrong (default)
- `"deploy"` — manifests are valid but deployment will fail (e.g. missing CRD
  in cluster, image doesn't exist)
- `"runtime"` — deploys fine but the application will crash or malfunction
  (e.g. missing postgres extension, undersized storage)

### 3. Evaluator changes (eval.nix)

The evaluator processes meta in `evaluateInstance`:

#### 3a. Meta validation (static, before build)

After `kixCallPackage` returns `raw`:

1. **k8s version check** — compare `meta.k8s.minVersion`/`maxVersion` against
   `clusterConfig.k8sVersion` (new cluster option). If out of range → assertion
   failure with `failurePhase = "deploy"`.

2. **Deprecation** — if `meta.deprecated != null`, emit a warning. If
   `deadline` has passed, promote to assertion failure.

3. **Conflict detection** — for each entry in `conflictsWith`, check if a
   matching instance exists in the resolution index. Namespace-scoped by
   default; `"cluster:"` prefix checks cluster-wide.

#### 3b. Dependency compatibility (after DI resolution)

4. **`compatibleWith` checks** — for each resolved dependency, if the dep
   arg name has a `compatibleWith` entry, compare the dep's version against
   min/max. Version source: `dep._meta.version` (from instance config) or
   `dep.out.version` (from package output). If incompatible → assertion with
   the `reason` message.

#### 3c. Package-declared diagnostics (after build)

5. **Call `warnings`** — pass `{ config, self, deps }` where `deps` is the
   resolved dependency attrset. Collect returned strings.

6. **Call `assertions`** — same args. Collect failed assertions.

#### 3d. Collection

All warnings and failed assertions are:
- Emitted immediately via `builtins.trace` (for nix build output)
- Collected on the cluster output as `cluster.warnings` and
  `cluster.failedAssertions` (for tooling/CI)

Failed assertions cause a `throw` after all instances are evaluated, so
you see ALL problems at once, not just the first.

### 4. Cluster-level options (modules.nix)

```nix
k8sVersion = lib.mkOption {
  type = lib.types.nullOr lib.types.str;
  default = null;
  description = "Target Kubernetes version (e.g. '1.30'). Used for package compatibility checks.";
};
```

### 5. `defaultAliases` in resolution

Currently aliases are set per-instance in the cluster definition:

```nix
instances.monitoring.prometheus = {
  package = packages.kube-prometheus-stack;
  aliases = [ "metrics" "monitoring" ];
};
```

With `meta.defaultAliases`, the package itself declares fallback aliases:

```nix
# In kube-prometheus-stack/default.nix
meta.defaultAliases = [ "metrics" "monitoring" ];
```

Resolution order:
1. Instance-level `aliases` (cluster definition) — always wins
2. `meta.defaultAliases` from the package — used when no instance aliases set

Implementation: in `buildResolutionIndex`, the static metadata already
includes aliases. We add `packageDefaultAliases` to `staticMeta` and merge
with instance aliases (instance wins on collision).

### 6. `meta.provides` (future-facing)

Tags are stored on the instance `_meta` for future use by:
- Auto-instantiation: "I need something that `provides = [ 'cache' ]`"
- Capability queries: "what provides 'metrics' in this cluster?"
- Documentation generation

No evaluator enforcement in this iteration — just propagation.

### 7. Known issues as assertions

The "encodable known issues" roadmap item maps directly to assertions with
descriptive messages and `failurePhase`:

```nix
assertions = { config, self, deps }: [
  {
    # Known issue: harbor chart 2.x doesn't support PG16
    assertion = (deps.postgres._meta.version or "15") != "16";
    message = "harbor chart 2.x is incompatible with PostgreSQL 16 — see harbor-helm#1234";
    failurePhase = "runtime";
  }
];
```

This captures institutional knowledge in code — the assertion message is
the documentation, and it can't silently become outdated because it's
evaluated every build.

## Migration

Existing ad-hoc validation in packages (immich trace/throw, n8n throws)
should be migrated to the new `warnings`/`assertions` fields. The old
patterns continue to work — this is additive.

## Roadmap items addressed

- [ ] General validation framework (line 18)
- [ ] Compatibility checks on packages (line 86)
- [ ] Compatibility matrix — four failure phases (line 89)
- [ ] Encodable "known issues" (line 90)
- [ ] Package-declared default aliases (line 25)
- [ ] Security defaults via mkDefault as auditable signal (line 58-60) — mkForce
      overrides can be detected via assertions in a future iteration
