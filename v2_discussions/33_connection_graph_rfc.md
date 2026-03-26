# RFC: Connection Graph

**Status:** Draft
**Date:** 2026-03-26
**Related:** `29_compiler-design.md` (sections 4.1, 4.2), `30_connection_graph.md` (prior exploration), `24_package_instance_wiring.md` (DI/wiring)

---

## 1. The Problem

DI tells the compiler that package A depends on package B. But the actual network connection — "A sends TCP traffic to B on port 5432" — is invisible. It lives in hand-written env vars, URL strings, and config file templates. This causes three concrete problems.

### 1.1 Duplicated, unvalidated internal URLs (Harbor)

Harbor has 6 internal components that reference each other. The internal URLs are manually constructed from string interpolation of the instance name:

```nix
# harbor/default.nix — today
coreInternalURL       = "http://${name}-core:80";
registryInternalURL   = "http://${name}-registry:5000";
registryCtlInternalURL = "http://${name}-registry:8080";
portalInternalURL     = "http://${name}-portal";
jobserviceInternalURL = "http://${name}-jobservice";
```

These URLs appear **9+ times** across ConfigMaps for Core, Jobservice, and Exporter. The ports (`80`, `5000`, `8080`) are magic numbers — if the registry changes from port 5000, you grep and pray. The compiler cannot verify that `"http://${name}-registry:5000"` corresponds to a real Service with that port.

Redis is worse: `"redis://${redisHost}:${redisPort}/0?idle_timeout_seconds=30"` is repeated for core, registry, and jobservice with only the DB index varying. The port `6379` is a string literal, not derived from any `out` field.

### 1.2 Hardcoded service names (Promtail)

Promtail ships logs to Loki with a hardcoded URL:

```nix
# promtail/default.nix — today
clients = [{
  url = "http://loki-gateway/loki/api/v1/push";
  tenant_id = "system";
}];
```

The string `"loki-gateway"` is an assumption about the Loki instance's Service name. If the Loki package is renamed, instantiated with a different name, or deployed in a different namespace, this silently breaks at runtime. Promtail does not even declare Loki as a DI dependency — the connection is completely invisible to the compiler.

### 1.3 Manual host/port wiring with fallback chains (n8n, Immich)

n8n constructs database and Redis connections through a two-tier fallback — config override, then DI dependency — with the port as a separate config string:

```nix
# n8n/default.nix — today
dbHost = if config.database.host != null then config.database.host
         else if postgres != null then postgres.out.fqdn
         else throw "n8n: database.host must be set or ...";

data = {
  DB_POSTGRESDB_HOST = dbHost;
  QUEUE_BULL_REDIS_HOST = redisHost;
  QUEUE_BULL_REDIS_PORT = config.redis.port;  # "6379" — string literal
};
```

Immich has the same pattern:

```nix
# immich/default.nix — today
env = kix.mkEnvVars {
  DB_HOSTNAME = postgres.out.fqdn;
  DB_PORT     = postgres.out.port;
  REDIS_HOSTNAME = valkey.out.fqdn;
  IMMICH_MACHINE_LEARNING_URL =
    if hasMl then "http://${machineLearning.out.fqdn}:${machineLearning.out.port}"
    else null;
};
```

The `DB_PORT` comes from `postgres.out.port` (good — validated), but the ML URL is manually formatted and assumes HTTP. If ML switches to gRPC or changes its port name, the compiler won't catch it.

### 1.4 What the compiler cannot answer today

Given the current codebase, the compiler cannot determine:

- **Who talks to whom on which port?** (the connection graph)
- **Is port 5432 actually exposed by postgres?** (port validation — only works if `out.port` is used, not for string literals like `"6379"`)
- **What NetworkPolicies are needed?** (requires knowing all network edges)
- **What breaks if postgres changes its port?** (blast radius — partially answered by Nix string context, but only for `out` field usage, not string literals)

---

## 2. Connection as a First-Class Edge

A connection is a typed, directional edge: **source workload -> target port**. It is distinct from both DI (which provides the reference) and env vars (which consume the connection). The connection declares: "I send network traffic to this endpoint."

### Relationship to DI

| Aspect | DI | Connection |
|---|---|---|
| Meaning | "I need a reference to B" | "I send traffic to B on port X" |
| Granularity | Per package | Per workload, per port |
| What it enables | Config access, `out` fields | NetworkPolicy, port validation, env wiring |
| Already exists? | Yes (function args) | No |

A package can depend on another without connecting to it (reading CRDs, using builder functions). A connection always implies a DI dependency, but not the reverse.

### What `out` exposes today

Infrastructure packages already expose port information through `out`:

```nix
# valkey: outputs = { port = "6379"; }
# stackgres-cluster: outputs = { port = "5432"; serviceName = "..."; }
```

The connection system builds on this — it references `out` fields, validates they exist, and derives env vars and policies from them.

---

## 3. Syntax Proposals

### 3.1 Alternative A: Explicit connection declarations (RBAC-style)

Connections are declared as a list of typed objects in `build`, separate from env vars. The package still writes its own env vars.

```nix
# immich/default.nix — Alternative A
{ scope, kix, postgres, valkey, machineLearning ? null, ... }:
{
  build = { self, config, ... }: {
    connections = [
      (kix.connect.tcp postgres "port")
      (kix.connect.tcp valkey "port")
    ] ++ lib.optional (machineLearning != null)
      (kix.connect.tcp machineLearning "port");

    # Env vars still written manually — connections are just metadata
    deployment = {
      spec.template.spec.containers = [{
        env = kix.mkEnvVars {
          DB_HOSTNAME = postgres.out.fqdn;
          DB_PORT = postgres.out.port;
          REDIS_HOSTNAME = valkey.out.fqdn;
        };
      }];
    } |> scope.mkDeployment;
  };
}
```

**Pros:**
- Minimal change to existing package structure.
- Follows the existing DSL pattern (mounts, RBAC intents).
- Connection metadata is collectible for NetworkPolicy derivation.
- Port validated at declaration time (`target.out.${portName}` throws if missing).

**Cons:**
- Parallel bookkeeping — you declare the connection AND write the env vars. They can drift.
- A connection declared without corresponding env vars, or env vars written without a connection declaration, are both silent errors.
- Does not reduce boilerplate.

### 3.2 Alternative B: Connection-aware env builder (recommended)

Connections are typed objects that also carry env var mappings. A single declaration serves as both the network intent and the env var source. This is the approach explored in `30_connection_graph.md`, refined here.

```nix
# immich/default.nix — Alternative B
{ scope, kix, postgres, valkey, machineLearning ? null, ... }:
{
  build = { self, config, ... }:
  let
    connections = {
      db = kix.connect.tcp postgres "port" {
        env.DB_HOSTNAME = target: target.out.fqdn;
        env.DB_PORT     = target: target.out.port;
      };
      redis = kix.connect.tcp valkey "port" {
        env.REDIS_HOSTNAME = target: target.out.fqdn;
      };
      ml = kix.connect.optional machineLearning "port" {
        env.IMMICH_MACHINE_LEARNING_URL = target:
          "http://${target.out.fqdn}:${target.out.port}";
      };
    };
  in {
    inherit connections;

    deployment = {
      spec.template.spec.containers = [{
        env = kix.mkEnvVars (
          kix.connectEnv connections // {
            # Non-connection config is still manual
            IMMICH_CONFIG_FILE = "...";
          }
        );
      }];
    } |> scope.mkDeployment;
  };
}
```

Where:

```nix
# kix.connect.tcp : target -> portName -> opts -> connection
kix.connect.tcp = target: portName: { env ? {} }: {
  _type = "kix-connection";
  protocol = "TCP";
  inherit target portName;
  _resolved = {
    host = target.out.fqdn;
    port = target.out.${portName}
      or (throw "connect: ${target.out.name} has no port '${portName}' in out");
  };
  envVars = lib.mapAttrs (_: fn: fn target) env;
};

# kix.connect.optional : target-or-null -> portName -> opts -> connection-or-null
kix.connect.optional = target: portName: opts:
  if target == null then null
  else kix.connect.tcp target portName opts;

# kix.connectEnv : connections-attrset -> env-attrset
# Merges all envVars from non-null connections.
kix.connectEnv = conns:
  lib.foldlAttrs (_: _: c:
    if c == null then {} else c.envVars
  ) {} conns;
```

**Pros:**
- Single source of truth — declaring the connection IS wiring the env vars.
- Port validated at construction time.
- `env` lambdas receive the target, so the package controls the env var name and format.
- Optional connections return `null`, which `connectEnv` filters out — no `if` boilerplate.
- Connection objects are collectible for NetworkPolicy derivation.
- Named attrset (not list) — connections are addressable by key for overrides.

**Cons:**
- Slightly more complex constructor (lambda per env var).
- Not all connections produce env vars (sidecar-to-sidecar, Helm charts that use config files). This is fine — `env = {}` is valid.
- Packages that use non-env-var config (YAML templates, CLI args) still need manual wiring alongside the connection.

### 3.3 Why Alternative B

Alternative A is strictly weaker — it provides the connection graph metadata but does not reduce manual wiring. Since the highest-value outcome is eliminating duplicated host/port strings, the connection declaration should be the source of truth for both network intent and env var values. Alternative B achieves this.

Alternative A remains available as a degenerate case: declare the connection with `env = {}` to register the network edge without deriving env vars. This is useful for Helm-wrapped packages where env wiring is inside the Helm chart.

---

## 4. What the Compiler Derives

### 4.1 Env var wiring (validated against target's `out`)

The `env` lambdas in a connection receive the target package. They can reference any `out` field. If the field does not exist, Nix evaluation fails with a clear error at build time — not at runtime in the container.

```nix
# This throws at build time if postgres removes out.port:
env.DB_PORT = target: target.out.port;
```

`kix.connectEnv` collects all env vars from a connections attrset, filtering nulls from optional connections. The result merges into the container's env alongside non-connection config.

### 4.2 NetworkPolicy rules

Given the full connection graph (all instances, all connections), the compiler derives:

- **Egress rule on source:** allows traffic from source's pods to target's pods on the declared port.
- **Ingress rule on target:** allows traffic from source's pods to target's pods on the declared port.

Both policies use `podSelector` from the source/target's `out.selector` and `namespaceSelector` when source and target are in different namespaces.

```
connection: immich (ns: apps) --tcp:5432--> postgres (ns: data)

produces:
  1. NetworkPolicy in "apps": immich egress to data/postgres on 5432
  2. NetworkPolicy in "data": postgres ingress from apps/immich on 5432
```

The platform engineer controls the posture:

```nix
# cluster module
namespaces.production.networkPolicy = {
  defaultPosture = "deny-all";      # baseline deny
  deriveFromConnections = true;      # compiler emits allow rules for declared connections
};
```

Derived policies are tagged `kix.dev/derived: "true"` to distinguish them from manually written policies. Manual policies take precedence on conflict.

### 4.3 Port consistency checking

The connection constructor validates `target.out.${portName}` at declaration time. This catches:

- Typos in port names (`"prot"` vs `"port"`)
- Removed ports (target package drops a port from `out`)
- Renamed ports (target switches from `out.port` to `out.ports.db`)

The error message lists available `out` fields so the package author can fix it immediately:

```
error: connect: stackgres-cluster has no port 'dbPort' in out
       available: port, serviceName, serviceNamePrimary, fqdn, name, selector
```

---

## 5. What the Package Still Controls

Connections are declarations of network intent, not opaque magic. The package retains control over:

### 5.1 Env var names

The package chooses its own env var names. Immich uses `DB_HOSTNAME`; n8n uses `DB_POSTGRESDB_HOST`. The connection system does not impose naming conventions.

```nix
# Immich's choice:
env.DB_HOSTNAME = target: target.out.fqdn;

# n8n's choice:
env.DB_POSTGRESDB_HOST = target: target.out.fqdn;
```

### 5.2 URL format strings

Some applications want `host:port`, others want `protocol://host:port/path`. The `env` lambda gives the package full control:

```nix
env.REDIS_URL = target:
  "redis://${target.out.fqdn}:${target.out.port}/0?idle_timeout_seconds=30";
```

### 5.3 Which connections are optional

Optional dependencies (`machineLearning ? null`) produce optional connections via `kix.connect.optional`. The connection is `null` when the dependency is absent, and `connectEnv` filters it. No special syntax needed beyond what DI already provides.

### 5.4 Non-env-var consumption

A connection with `env = {}` registers the network edge for NetworkPolicy derivation without producing env vars. The package consumes the target's `out` fields however it wants — YAML templates, CLI arguments, config files.

### 5.5 Overrides and escape hatches

The connections attrset is a regular Nix value. Cluster-level overrides can replace individual connections. A package can also bypass the connection system entirely and wire env vars manually — the compiler just won't know about that network edge.

---

## 6. Interaction with DI

Connections build on top of DI. The dependency is already resolved and injected — the connection adds the semantic: "I actually send traffic to this dependency on this port."

### 6.1 Connections imply dependencies

Every connection target must be a DI dependency (or an `out` from a self-reference). The connection constructor validates this by accessing `target.out` — if the target is not a real package instance, it fails.

### 6.2 Not every dependency is a connection

A package that uses `cert-manager`'s `withCert` builder function depends on cert-manager but does not connect to it. RBAC references, CRD imports, builder function usage — these are DI dependencies without network connections.

### 6.3 DI provides the target, connections provide the edge

```
DI graph:       immich --depends-on--> postgres
Connection graph: immich --tcp:5432--> postgres
```

The DI graph is the superset. The connection graph is a subset that represents actual network traffic. NetworkPolicies derive from the connection graph, not the DI graph.

### 6.4 Optional connections follow optional DI

```nix
{ machineLearning ? null, ... }:  # DI: optional dependency
{
  build = ...:
  let
    connections = {
      ml = kix.connect.optional machineLearning "port" { ... };
      # ml is null when machineLearning is null
    };
  in ...
}
```

No new optionality mechanism needed — `kix.connect.optional` is a thin wrapper over `kix.connect.tcp` that short-circuits on `null`.

---

## 7. Intra-Package Connections (Harbor pattern)

Harbor's 6 components talk to each other within a single package. These are intra-package connections — the source and target are both `self.*` resources, not DI dependencies.

This is a harder problem. The current proposal focuses on inter-package connections (DI dependencies). Intra-package wiring is already partially handled by `service.fromWorkload` and `ingress.fromService`. Extending the connection model to intra-package edges is future work.

For now, Harbor-style packages benefit from the connection model for their external dependencies (postgres, potentially external Redis) and continue using `self.*.out` for internal wiring. The compiler gains visibility into the external edges even without modeling the internal ones.

---

## 8. Migration Path

Adoption is incremental. No flag day. Packages migrate one at a time.

### Step 1: Add `kix.connect.*` and `kix.connectEnv` to kixlib

Pure functions, no evaluator changes. Existing packages are unaffected.

### Step 2: Migrate a simple package (Immich)

Immich has 3 clear connections (postgres, valkey, optional ML). Replace manual env var construction with connection-derived env vars. Verify identical output YAML.

```nix
# Before:
env = kix.mkEnvVars {
  DB_HOSTNAME = postgres.out.fqdn;
  DB_PORT = postgres.out.port;
  REDIS_HOSTNAME = valkey.out.fqdn;
  IMMICH_MACHINE_LEARNING_URL = mlUrl;
};

# After:
env = kix.mkEnvVars (kix.connectEnv connections // {
  IMMICH_CONFIG_FILE = ...;
  IMMICH_TELEMETRY_INCLUDE = ...;
});
```

### Step 3: Collect connections in instance.nix

The evaluator scans `parts` for `_type = "kix-connection"` objects. Store connection metadata on `PackageInstance` annotations:

```nix
annotations."kix.dev/connections" = builtins.toJSON (
  lib.mapAttrsToList (_: c: {
    target = builtins.unsafeDiscardStringContext c.target.out.name;
    port = builtins.unsafeDiscardStringContext c._resolved.port;
    protocol = c.protocol;
  }) (lib.filterAttrs (_: c: c != null) allConnections)
);
```

### Step 4: Migrate more packages

n8n (postgres + valkey), metabase (postgres), python-app. Each migration is a single-package change with verifiable output.

### Step 5: NetworkPolicy derivation (cluster pass)

Walk all connection edges across all instances. Emit ingress/egress policies per namespace. Gate behind `networkPolicy.deriveFromConnections = true` initially. Compare derived policies against what would be hand-written.

### Step 6: CLI visualization

`kix graph --connections` parses `kix.dev/connections` annotations and renders network edges. `kix impact postgres --port 5432` shows blast radius.

---

## 9. Concrete Syntax for Common Patterns

### 9.1 Basic host + port (Immich -> Postgres)

```nix
connections.db = kix.connect.tcp postgres "port" {
  env.DB_HOSTNAME = target: target.out.fqdn;
  env.DB_PORT     = target: target.out.port;
};
```

### 9.2 URL format (Immich -> ML service)

```nix
connections.ml = kix.connect.optional machineLearning "port" {
  env.IMMICH_MACHINE_LEARNING_URL = target:
    "http://${target.out.fqdn}:${target.out.port}";
};
```

### 9.3 Redis with DB index (n8n -> Valkey)

```nix
connections.redis = kix.connect.tcp valkey "port" {
  env.QUEUE_BULL_REDIS_HOST = target: target.out.fqdn;
  env.QUEUE_BULL_REDIS_PORT = target: target.out.port;
};
```

### 9.4 Connection without env vars (Helm package, NetworkPolicy only)

```nix
connections.db = kix.connect.tcp postgres "port" {};
```

### 9.5 envPrefix shorthand (convenience)

For the common `PREFIX_HOST` / `PREFIX_PORT` pattern, a shorthand:

```nix
kix.connect.tcp postgres "port" { envPrefix = "DB"; }
# Equivalent to:
# env.DB_HOST = target: target.out.fqdn;
# env.DB_PORT = target: target.out.port;
```

The shorthand and explicit `env` can coexist — explicit wins on key conflict.

---

## 10. Open Questions

1. **Port naming convention.** Packages expose ports inconsistently: `out.port` (singular, most packages), `out.metricsPort` (valkey). Should there be a standard `out.ports` sub-attrset (`out.ports.db`, `out.ports.metrics`)? Or is the flat namespace (`out.port`, `out.metricsPort`) sufficient for now?

2. **External connections.** What about connections to services outside the cluster (managed databases, SaaS APIs)? These cannot be DI dependencies. Options: (a) out of scope — kix only models in-cluster connections; (b) `kix.connect.external "host" port {}` for NetworkPolicy egress rules only.

3. **NetworkPolicy ownership.** When the compiler derives a NetworkPolicy from the connection graph, which package "owns" it? The recommendation from `30_connection_graph.md` is namespace-owned (derived policies sit alongside explicit namespace policies). Is this the right call, or should they be attached to the source/target instance?

4. **Multi-port services.** A package exposing HTTP (8080) and gRPC (9090) — the connection specifies which port, but `out.port` is typically the "primary." Do we need to formalize a multi-port convention, or is `out.port` / `out.grpcPort` / `out.metricsPort` fine?

5. **Selector availability for Helm packages.** NetworkPolicy derivation needs `out.selector` on both source and target. Helm-wrapped packages may not propagate selectors through `out`. Do we need a mechanism to declare selectors for Helm packages that the connection system can consume?

6. **Same-package connections (Harbor).** Harbor's components are all within one package. Should the connection system cover intra-package edges, or is that a separate concern? The `service.fromWorkload` pipeline already handles some of this.

7. **Connection from non-Deployment resources.** CronJobs, Jobs, and DaemonSets produce pods and have network behavior. The connection model should work for any pod-producing resource. Does the current design handle this naturally, or do we need explicit support?

8. **Validation strictness.** If a package declares `connections` but also manually writes env vars referencing `target.out.fqdn` outside a connection, should the compiler warn? This is the "parallel bookkeeping" problem from Alternative A — even with Alternative B, a package could bypass `connectEnv` for some vars.

9. **`envPrefix` vs explicit `env`.** Is the `envPrefix` shorthand worth the complexity? It introduces an opinion about naming (`PREFIX_HOST`, `PREFIX_PORT`) that may not match what applications expect. The explicit `env` lambda is more flexible but more verbose.
