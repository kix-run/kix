# Deps out of package function — derive from build args

## Design

Deps are **discovered from build function args**, not declared in the package function.

**Before:**
```nix
{ scope, lib, kix, postgres, ingressNginx ? null }:
{
  meta = { ... };
  options = { ... };
  build = { self, config, ... }: { ... };
}
```

**After:**
```nix
{ scope, lib, kix }:
{
  meta = { ... };
  options = { ... };
  build = { self, config, postgres, ingressNginx ? null, ... }: { ... };
}
```

### Key properties

- **Single source of truth** — deps declared exactly once, in build function args
- **Natural Nix syntax** — `postgres` = required, `ingressNginx ? null` = optional
- **No peekPackageMeta hack** — package function has no deps, call freely with system args
- **No double bookkeeping** — no separate `deps` attrset for basic dep declaration

### Optional `deps` enrichment

Packages can add a `deps` attrset for per-dep diagnostics (assertions/warnings).
This is **enrichment only** — deps are still discovered from build args.

```nix
{ scope, lib, kix }:
{
  deps = {
    postgres.assertions = dep:
      lib.optional (!(builtins.elem "vectors" (dep.out.extensionNames or []))) {
        assertion = false;
        message = "immich requires pgvecto.rs extension";
      };
    storage.warnings = dep:
      lib.optional ((kix.parseGi (dep.out.size or "0")) < 50)
        "storage < 50Gi — recommended minimum for photo libraries";
  };
  build = { self, config, postgres, storage, ... }: { ... };
}
```

### Eval system flow

1. `callPackagePhase1` — call package with system args only → `{ meta, options, deps?, build }`
2. `discoverBuildDeps` — introspect build function args, strip system args → dep names + optionality
3. `resolveDeclaredDeps` — DNS-like resolution against cluster instances
4. `callBuildFn` — pass resolved deps by name (+ as `deps` attrset if requested)
5. Evaluate per-dep assertions/warnings from `deps` enrichment

### System args (not deps)

**Package function:** `scope`, `lib`, `kix`
**Build function:** `self`, `config`, `clusterConfig`, `scope`, `lib`, `kix`, `deps`

Everything else in build function args is treated as a dep.

## Implementation

### Eval infrastructure (4 files)

- `lib/eval/resolve.nix` — `callPackagePhase1`, `discoverBuildDeps`, `resolveDeclaredDeps` (replaced `kixCallPackage`)
- `lib/eval/instance.nix` — two-phase eval, build-arg dep discovery, per-dep diagnostics
- `lib/meta.nix` — simplified `peekPackageMeta` (no tryEval), `evaluatePackageDiagnostics` handles dep enrichment
- `lib/eval/auto.nix` — `getRequiredDeps` calls package phase1, introspects build args

### Migrated packages (12)

cluster-issuers, coredns, firezone, harbor, immich, metabase, n8n,
network-policies, persistent-volume-claim, python-app, stackgres-cluster, velero

### Test fixtures

- `clusters/test-auto.nix` — inline test packages updated
