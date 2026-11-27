# 59 — Load Estimation: Demand Aggregation Across the Dependency Graph

**Status:** RFC — Draft
**Related:** `42_dep_config_injection.md` (mechanism this builds on), `45_cluster_hardware_profile.md` (supply side), `48_system_contracts.md` (compile-time verification), `49_topology_aware_monitoring.md` (graph-derived features)

---

## Problem

kix knows the full dependency graph at compile time. It knows that immich, n8n, and vaultwarden all depend on the same postgres instance. But postgres has no way to size itself based on that knowledge. Today, postgres gets static defaults (`cpu: 1`, `memory: 2Gi`, `maxConnections: 200`) and the cluster operator manually guesses whether those are right.

This is the **demand side** of cluster planning. The hardware profile (doc 45) describes the **supply** — what the cluster has. Load estimation would describe the **demand** — what packages need. Together they close the loop: is there enough supply for the demand? Is each shared service sized for its consumers?

The postgres example is concrete but the concept is general. Any shared service faces the same problem:

| Shared service | What consumers impose | What the service needs to know |
|---|---|---|
| **PostgreSQL** | connections, storage, extensions, query complexity | max_connections, shared_buffers, CPU, memory, storage size |
| **Valkey/Redis** | memory pressure, connection count, pub/sub channels | maxmemory, maxclients |
| **Ingress controller** | number of ingress rules, TLS termination load, rate limits | replica count, CPU/memory, connection buffer sizes |
| **Storage provisioner** | total PVC volume, IOPS requirements | pool sizing, replication factor |
| **Monitoring stack** | scrape targets, cardinality, retention needs | storage, memory, scrape interval |
| **cert-manager** | number of certificates, renewal frequency | replica count, rate limits |

In every case: the consumers know what they need, the provider knows how to translate aggregate demand into sizing — but there's no channel between them.

## What "load" actually is

Load is not a single number. It's a **per-dependency-type contract** — the provider defines what dimensions of demand matter, and consumers fill in their estimates. This is crucial: the provider is the authority on what dimensions exist, not the consumer.

### Dimensions are provider-defined

Postgres cares about connections, storage, and extensions. Valkey cares about memory and connections. An ingress controller cares about rule count and TLS termination. The consumer doesn't invent these dimensions — the provider declares them, with defaults.

This means load isn't a generic `{ cpu, memory }` attrset slapped onto every dep. It's **typed per provider**, just like config injection is typed per provider's options.

### Load vs. config

Config injection (doc 42) says: "set this value on my dependency." Load says: "I will impose this much demand on my dependency." The distinction:

| | Config injection | Load declaration |
|---|---|---|
| **Semantics** | "postgres must have the vectors extension" | "I'll use ~20 connections and ~50Gi storage" |
| **Merge strategy** | Module system merge (lists append, scalars conflict) | **Summation** — demands add up |
| **Who defines the schema** | Provider's options | Provider's `loadDimensions` |
| **Who consumes the result** | Provider's config (via evalModules) | Provider's build function (as aggregated demand) |
| **Can the cluster author override?** | Yes, via instance config (higher priority) | Yes — final sizing is still a config option |

Load declarations are **additive** by nature. If immich wants 20 connections and n8n wants 15, postgres needs at least 35. This is fundamentally different from config, where two consumers setting the same scalar is a conflict.

### Load vs. resource requests/limits

K8s resource requests/limits are the *output* of load estimation, not the input. A package doesn't say "I need 2Gi of memory from postgres." It says "I'll open 20 connections with medium-complexity queries." Postgres translates that aggregate demand into concrete memory/CPU/connection settings. The consumer describes *behavior*; the provider translates to *resources*.

## Who specifies load

There are four actors who might contribute to a service's sizing:

### 1. The consumer package (demand declaration)

The package that depends on a shared service declares what it expects to use. This is the **demand signal** — it flows through the same `deps` enrichment channel as config injection.

```nix
# immich/default.nix
deps = {
  postgres.config = { extensions = [{ name = "vectors"; ... }]; };
  postgres.load = {
    connections = 20;
    storageGiB = 50;
    queryComplexity = "heavy";  # qualitative hint
  };
};
```

Not every consumer will specify load. That's fine — the provider declares defaults (see below).

### 2. The provider package (default demand + aggregation logic)

The provider defines:
- **What dimensions exist** — the schema of a load declaration
- **Default demand per dependent** — what to assume when a consumer doesn't specify
- **How to aggregate** — the function from demand list → sizing

```nix
# stackgres-cluster/default.nix
{
  loadDimensions = {
    connections = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Expected number of database connections";
    };
    storageGiB = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Expected storage usage in GiB";
    };
    queryComplexity = lib.mkOption {
      type = lib.types.enum [ "light" "medium" "heavy" ];
      default = "medium";
    };
  };

  build = { self, config, dependentLoads, ... }:
  let
    totalConns = lib.foldl' (acc: dl: acc + dl.load.connections) 0 dependentLoads;
    totalStorageGiB = lib.foldl' (acc: dl: acc + dl.load.storageGiB) 0 dependentLoads;
    heavyClients = lib.count (dl: dl.load.queryComplexity == "heavy") dependentLoads;

    # Translate demand into sizing
    derivedMemoryMB = builtins.max 2048 (totalConns * 10 + heavyClients * 512);
    derivedMaxConns = toString (totalConns + 20);  # headroom
    derivedStorageSize = "${toString (builtins.max 20 totalStorageGiB)}Gi";
  in {
    # ... use derivedMemoryMB, derivedMaxConns, derivedStorageSize
    # to set instanceProfile, pgConfig, storage.size
  };
}
```

The provider is in complete control of how demand maps to resources. The consumer doesn't say "give postgres 4Gi of memory" — it says "I'll use 20 connections" and postgres decides what that means.

### 3. The cluster operator (overrides + caps)

The cluster operator has final say. Load-derived sizing produces **defaults** that the operator can override via instance config:

```nix
# cluster definition
instances.database.postgres = {
  package = packages.stackgres-cluster;
  config = {
    # Override derived sizing — maybe the operator knows better
    instanceProfile.memory = "8Gi";
    pgConfig.maxConnections = "500";
    # Or let load estimation drive it by not setting these
  };
};
```

The priority chain is:
1. Provider's hardcoded defaults (lowest)
2. **Load-derived sizing** (computed from aggregate demand)
3. Global config
4. Instance config from cluster operator (highest — final say)

This means load estimation is a *better default*, not a mandate. The cluster author can always override.

### 4. The cluster hardware profile (physical constraints)

The hardware profile (doc 45) provides the supply ceiling. `cluster.nodes` describes available CPU/memory. Load estimation produces demand. A future compile-time check could verify: does the aggregate demand fit on this hardware?

```
demand: postgres wants 8Gi, valkey wants 2Gi, 5 workloads want 500m CPU each
supply: 3 nodes × 16Gi RAM, 4 vCPU
→ fits (with headroom for kube-system)

demand: same but 20 workloads
supply: 1 node × 8Gi RAM, 2 vCPU
→ warning: aggregate requests exceed node capacity
```

This is a natural extension but not part of the core load mechanism — it's a cluster-level validation pass.

## What load depends on

Load is not just a static number. In practice, it depends on several factors:

### Environment / profile

Dev clusters need 1/10th the resources. Staging needs moderate. Prod needs full sizing. The load declarations from packages are *production estimates*. The cluster's environment should scale them:

```nix
# Possible: environment-aware scaling on the demand
# The cluster operator configures a load scaling factor
global.loadScale = 0.1;  # dev cluster — everything gets 10% of estimated load
```

Or the provider's aggregation function reads `clusterConfig` and applies a profile:

```nix
build = { self, config, dependentLoads, clusterConfig, ... }:
let
  scale = { production = 1.0; staging = 0.5; development = 0.1; }.${clusterConfig.global.environment or "production"};
  totalConns = lib.foldl' (acc: dl: acc + dl.load.connections) 0 dependentLoads;
  scaledConns = builtins.ceil (totalConns * scale);
in ...
```

This connects to the ROADMAP item: "Per-environment overrides (dev: resources /10, staging: no limits, prod: full limits)."

### Number of dependents (the "5 × default" case)

If 5 packages depend on postgres but only immich specifies load, the system uses:
- immich's explicit load: `{ connections = 20; storageGiB = 50; }`
- 4 × provider's default: `{ connections = 5; storageGiB = 2; }` each
- Total: `{ connections = 40; storageGiB = 58; }`

This is the user's original insight: every dependent imposes *some* load even if they don't specify it. The default is not zero — it's the provider's best guess for a "typical" consumer.

### Consumer's own config

A consumer's load may depend on its own configuration. Immich with `replicaCount = 3` needs 3× the connections of `replicaCount = 1`. This is tricky because load declarations are in `deps` (phase-1, before config evaluation), but the consumer's config hasn't been evaluated yet.

Options:
- **Static load** (simplest): load declarations are constants, set in `deps`. The package author estimates for a typical deployment. This is good enough for 80% of cases.
- **Config-aware load** (future): load is a function of the consumer's evaluated config. This requires load to be computed after config evaluation but before the provider's build. Introduces a new phase dependency. Worth considering but not essential for v1.

```nix
# Future possibility — load as a function of config
deps.postgres.load = config: {
  connections = config.replicaCount * 10;
  storageGiB = 50;
};
```

This would require the phase-1 pre-pass to evaluate consumer configs before computing load, which changes the eval order. Park this for now.

### Qualitative vs. quantitative

Not all load dimensions are numbers. `queryComplexity = "heavy"` is a qualitative signal that postgres can use to decide on CPU allocation or parallelism settings. This is valuable — it lets the consumer express intent without needing to know postgres internals.

The provider translates qualitative signals into quantitative sizing. The consumer says "I do heavy queries" (true — pgvecto.rs is compute-intensive). Postgres decides that means +512MB memory and +0.5 CPU per heavy client.

## How it flows through the system

The mechanism mirrors config injection (doc 42) because it uses the same phase-1 pre-pass infrastructure:

```
Phase 1 (pre-pass, outside fixpoint):
  for each instance:
    raw = callPackagePhase1(package, minimalScope)
    depsEnrichment = raw.deps  ← already collected for config injection
    loadDeclarations = raw.deps.*.load  ← NEW: extract load from enrichment

  configInjections = buildConfigInjections(phase1Map)     ← existing
  loadAggregations = buildLoadAggregations(phase1Map)     ← NEW

Phase 2 (fixpoint):
  for each instance:
    evaluateInstance({
      ...
      configInjections = ...     ← existing
      dependentLoads = ...       ← NEW
    })
```

### `buildLoadAggregations`

Inverts the dependency graph (same as `buildConfigInjections`) but instead of collecting config modules, collects load declarations and fills defaults for consumers who didn't specify:

```nix
buildLoadAggregations = { phase1Map, ... }:
  # 1. For each instance, collect its loadDimensions defaults (from phase-1 result)
  # 2. For each dep edge, check if the consumer declared deps.X.load
  # 3. If yes, use consumer's load (validated against loadDimensions schema)
  # 4. If no, use the provider's loadDimensions defaults
  # 5. Group by target: { ns.inst = [ { source, load } ]; }
```

### Inside the build function

The provider receives `dependentLoads` as a new system build arg — a list of `{ source, load }` entries:

```nix
dependentLoads = [
  { source = "media/immich"; load = { connections = 20; storageGiB = 50; queryComplexity = "heavy"; }; }
  { source = "tools/n8n"; load = { connections = 5; storageGiB = 2; queryComplexity = "medium"; }; }
  { source = "tools/vaultwarden"; load = { connections = 5; storageGiB = 2; queryComplexity = "light"; }; }
]
```

The `source` field enables diagnostics: "postgres allocated 500 max_connections because immich declared 20, n8n declared 5 (default), vaultwarden declared 5 (default), + 20 headroom."

## What this enables beyond sizing

### Compile-time capacity planning

With load on the demand side and the hardware profile on the supply side, the compiler can verify that the cluster has enough resources:

```
warning: cluster 'ludo' — aggregate derived memory requests (12.5Gi) exceed
  total node memory (8Gi). Consider scaling down or adding nodes.

  Breakdown:
    postgres: 4Gi (derived from 40 connections across 5 consumers)
    valkey: 1Gi (derived from 3 consumers)
    immich: 2Gi (static request)
    n8n: 1.5Gi (static request)
    ...
```

### Cost estimation

If node costs are known (from the hardware profile or a pricing module), load-derived sizing enables cost estimation at compile time:

```
info: cluster 'prod' estimated monthly cost: ~$180
  3× n2-standard-4 ($0.19/hr × 720hr) = $410
  resource utilization: 62% CPU, 78% memory
```

This is speculative but the data foundation is there.

### Environment-aware scaling

The "dev = 1/10th" pattern becomes systematic rather than per-package:

```nix
# Instead of every package having:
#   resources.limits.memory = if env == "dev" then "256Mi" else "2Gi";
# The cluster operator sets a global scale factor
# and load-derived sizing handles it automatically.
global.loadScale = 0.1;
```

### Dependency-aware alerting (connects to doc 49)

If postgres is sized for 40 connections and monitoring sees 38 in use, the alert can reference the load model: "postgres connection usage at 95% of load-derived capacity (40). Consumers: immich (20 allocated), n8n (5), vaultwarden (5), headroom (10)."

## Design decisions to make

### 1. Where do `loadDimensions` live?

Options:
- **Top-level in the phase-1 result** (alongside `meta`, `options`, `deps`, `build`). This makes it a first-class concept. The provider's package explicitly declares "I accept load declarations from my dependents."
- **Inside `options`** (as a special option type). Reuses the existing config system but conflates "things the operator configures" with "things consumers declare."
- **Inside `meta`**. The user explicitly said not this — and they're right. Load dimensions are about the DI relationship, not package metadata.

Recommendation: **top-level**. It's a new concept that deserves its own slot:

```nix
{ scope, lib, kix }:
{
  meta = { ... };
  options = { ... };
  loadDimensions = { ... };   # NEW — what dimensions of demand consumers can declare
  deps = { ... };
  build = { ... };
}
```

### 2. Are `loadDimensions` module-system options?

Using `lib.mkOption` for load dimensions gives us:
- Type checking on consumer declarations
- Defaults (the "per-dependent default")
- Documentation

But it also brings merge semantics we might not want (load should sum, not merge). The load values from each consumer should be kept separate — the provider aggregates them in `build`, not the module system.

Recommendation: `loadDimensions` uses `lib.mkOption` for **schema + defaults only**. Each consumer's load is independently evaluated against the schema. The build function receives a list, not a merged result.

### 3. What happens when a package has no dependents?

If postgres is deployed but nothing depends on it (yet), `dependentLoads` is `[]`. The provider falls back to its hardcoded option defaults. This is correct — the feature is purely additive.

### 4. Should consumers see their own load contribution?

Maybe. If immich declares `{ connections = 20 }` and postgres sizes for 40, immich might want to verify: "did postgres allocate enough for me?" This would be an assertion on the resolved dep, similar to the existing `deps.postgres.assertions`. The consumer could check `dep.out.maxConnections >= 20` after sizing.

### 5. Can the cluster operator add load entries?

What if the operator knows about external consumers (a microservice not managed by kix that also hits postgres)? They should be able to inject additional load:

```nix
instances.database.postgres = {
  package = packages.stackgres-cluster;
  # Extra load from non-kix consumers
  extraLoad = [
    { source = "external/legacy-api"; load = { connections = 30; storageGiB = 100; }; }
  ];
};
```

This is a natural extension — add it to the instance module options.

## Open questions

1. **Config-aware load**: Should load declarations be allowed to reference the consumer's own config (`config.replicaCount * 10`)? This adds a phase dependency — the consumer's config must be evaluated before load is aggregated. Might be needed for accuracy but adds complexity.

2. **Load as a contract**: Should the provider be able to *reject* a load it can't serve? E.g., "this postgres instance is capped at 100 connections by cluster policy, but consumers declared 150." This is an assertion on the aggregate, which the provider can already do in its build function.

3. **Transitive load**: If A depends on B which depends on postgres, does A's load on B contribute to B's load on postgres? Probably not directly — B's load on postgres is B's own declaration. But B might want to size itself based on *its* dependents, and that sizing affects how much it loads onto postgres. This is naturally handled by the fixpoint if B's load declaration on postgres is static.

4. **Qualitative dimension composition**: If immich says `queryComplexity = "heavy"` and n8n says `queryComplexity = "light"`, how does postgres combine them? It's a list, not a merge — postgres sees both and decides (e.g., "at least one heavy client → allocate for complex queries"). This works naturally with the list-of-loads model.

5. **Relationship to `cluster.nodes`**: When load-derived sizing produces resource requests, should the compiler check them against `cluster.nodes` capacity? This is a cluster-level validation pass, not part of the load mechanism itself. Separate concern, separate implementation, but enabled by load estimation.

6. **Observability of the load model**: Should `kix info` or the CLI show the load model? "postgres sized for 40 connections (immich: 20, n8n: 5 default, vaultwarden: 5 default, headroom: 10)." Useful for cluster operators to understand why things are sized the way they are.
