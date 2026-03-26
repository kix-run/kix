# Connection Graph

## Working Document — March 2026

**Status:** Design draft
**Related:** `29_compiler-design.md` (§4.1, §4.2, §4.3), `24_package_instance_wiring.md` (DI/wiring)

---

## 1. The Problem

DI gives package A a reference to package B. But the actual network connection — "A sends TCP traffic to B on port 5432" — is invisible to the compiler. It's buried in manual env var construction:

```nix
# n8n/default.nix — today's pattern
dbHost = if postgres != null then postgres.out.fqdn else throw "...";
configmap = scope.mkResource {
  data = {
    DB_POSTGRESDB_HOST = dbHost;
    DB_POSTGRESDB_PORT = "5432";  # magic string, not validated
  };
};
```

The compiler can't answer:
- **Who talks to whom?** (connection graph)
- **Is port 5432 actually exposed by postgres?** (port validation)
- **What NetworkPolicies are needed?** (policy derivation)
- **What breaks if postgres changes its port?** (blast radius)

The DI graph says "A depends on B." The connection graph says "A sends TCP traffic to B's `db` port."

---

## 2. What a Connection Is

A connection is a typed, directional edge: **source workload → target service port**.

It is NOT:
- A dependency (DI already handles that)
- An env var (that's how the connection is *consumed*, not what it *is*)
- A Service resource (that's how the connection is *routed*, not what it *is*)

It IS:
- A declaration of network intent: "this workload needs to reach that endpoint"
- Enough information to derive: env vars, NetworkPolicy rules, port validation

### Connection vs. DI

| | DI | Connection |
|---|---|---|
| What it means | "I need a reference to B" | "I send traffic to B on port X" |
| Granularity | Per package | Per workload → per port |
| Already exists? | Yes (function args) | No |
| Enables | Config access, out fields | NetworkPolicy, port validation, env wiring |

A package can depend on another without connecting to it (e.g., reading its CRDs, using its builder functions). A connection always implies a dependency, but not the reverse.

---

## 3. Design Exploration: Three Approaches

### 3.1 Explicit connection declarations (RBAC-style)

Packages declare connections as typed objects, like mounts or RBAC intents:

```nix
# In compose.nix (kixlib)
connect = {
  # TCP connection to a dependency's named port.
  tcp = target: portName: {
    _type = "kix-connection";
    protocol = "TCP";
    inherit target portName;
  };

  # UDP variant.
  udp = target: portName: {
    _type = "kix-connection";
    protocol = "UDP";
    inherit target portName;
  };
};
```

Package usage:

```nix
# n8n/default.nix
{ scope, kix, postgres, valkey, ... }:
{
  build = { self, config, ... }: {
    connections = [
      (kix.connect.tcp postgres "db")
      (kix.connect.tcp valkey "valkey")
    ];

    deployment = { ... } |> scope.mkDeployment;

    # env vars still manual — connections don't dictate HOW you consume them
    configmap = scope.mkResource {
      data = {
        DB_HOST = postgres.out.fqdn;
        DB_PORT = postgres.out.port;
        REDIS_HOST = valkey.out.fqdn;
      };
    };
  };
}
```

**Pros:** Explicit, auditable, follows existing DSL patterns (mounts, RBAC).
**Cons:** Parallel bookkeeping — you declare the connection AND write the env vars. Can drift.

### 3.2 Derived from `out` field usage (implicit)

The compiler detects connections by observing which `out` fields are used. If package A reads `postgres.out.fqdn`, there's an implicit connection. Nix string context already tracks this at the store-path level — but it tracks *data* dependencies, not *network* dependencies. Reading `postgres.out.name` to construct an annotation is not a network connection.

The distinction: `out.fqdn` and `out.port` are *network-relevant* fields. The compiler could tag certain `out` fields as "network endpoints" and treat their use as implicit connection edges.

```nix
# In k8s.nix — mark network-relevant outputs
outputs = {
  fqdn = { value = "..."; _network = true; };
  port = { value = "5432"; _network = true; };
  name = "...";  # not network — no edge
};
```

**Pros:** Zero boilerplate — packages don't change at all.
**Cons:** Fragile. Can't distinguish "I connect to postgres" from "I display postgres's hostname in a dashboard." Over-derives connections. And mutating `out` field types from strings to attrsets would break every consumer.

### 3.3 Connection-aware env var builder (recommended)

Merge the connection declaration with the env var wiring. Instead of declaring connections separately and ALSO writing env vars, the connection IS the env var wiring:

```nix
# In compose.nix (kixlib)
connect = {
  # Declare a connection AND derive env vars from it.
  # Returns a kix-connection object that also carries env var mappings.
  tcp = target: portName: {
    envPrefix ? null,
    env ? {},
  }: {
    _type = "kix-connection";
    protocol = "TCP";
    inherit target portName;
    # Resolved at build time from target.out
    _resolved = {
      host = target.out.fqdn;
      port = target.out.${portName} or (throw
        "connection: target '${target.out.name}' has no port '${portName}' in out");
    };
    # Env var mappings — auto-generated from prefix OR manual
    envVars =
      (if envPrefix != null then {
        "${envPrefix}_HOST" = target.out.fqdn;
        "${envPrefix}_PORT" = target.out.${portName} or (throw
          "connection: target '${target.out.name}' has no port '${portName}' in out");
      } else {})
      // env;
  };
};

# Collect env vars from connections.
connectEnv = connections:
  builtins.foldl' (acc: c: acc // c.envVars) {} connections;
```

Package usage:

```nix
# n8n/default.nix
{ scope, kix, postgres, valkey, ... }:
{
  build = { self, config, ... }:
  let
    connections = [
      (kix.connect.tcp postgres "port" { envPrefix = "DB"; })
      (kix.connect.tcp valkey "port" { envPrefix = "REDIS"; })
    ];
  in {
    inherit connections;

    configmap = scope.mkResource {
      data = kix.connectEnv connections // {
        # DB_HOST, DB_PORT, REDIS_HOST, REDIS_PORT are auto-derived
        DB_TYPE = "postgres";  # non-connection config is still manual
      };
    };
  };
}
```

**Pros:**
- Single source of truth — no parallel bookkeeping
- Port validated at declaration time (throws if `out.${portName}` missing)
- Env vars derived, not hand-written
- Connection objects are collectible for NetworkPolicy derivation
- Follows the mount pattern: typed object → injection

**Cons:**
- Not all connections produce env vars (e.g., sidecar → sidecar)
- `envPrefix` is an opinion about naming — some packages want `DATABASE_URL` not `DB_HOST`/`DB_PORT`

---

## 4. Recommended Design

**Approach 3.3** with escape hatches. The core idea: connections are typed objects in `parts`, like mounts. They serve dual purpose — network intent declaration AND env var derivation. But env var derivation is optional; the connection edge exists regardless.

### 4.1 Connection Object

```nix
# compose.nix addition
connect = {
  # Core constructor. Returns a connection object.
  tcp = target: portName: opts: { ... };  # as above
  udp = target: portName: opts: { ... };

  # URL-style connection (for protocols that use URIs).
  # Derives: REDIS_URL = "redis://host:port"
  url = target: portName: { scheme, envVar, pathSuffix ? "" }: {
    _type = "kix-connection";
    protocol = "TCP";
    inherit target portName;
    _resolved = { ... };
    envVars = {
      ${envVar} = "${scheme}://${target.out.fqdn}:${target.out.${portName}}${pathSuffix}";
    };
  };
};
```

### 4.2 Collection in Instance Evaluation

`instance.nix` already collects typed objects via `collectTypedAttrs`. Connections are collected the same way:

```nix
# In instance.nix, after building parts:
allConnections = builtins.filter
  (v: (v._type or "") == "kix-connection")
  (collectTypedAttrs { excludeKeys = ["main" "meta"]; } parts);
```

This gives the evaluator the full connection graph for the instance — which targets it connects to, on which ports, with which protocol.

### 4.3 Connection Metadata on PackageInstance

The connection edges are stored on the PackageInstance CRD as annotations or spec fields, so the CLI can read them without re-evaluating Nix:

```nix
# In k8s.nix mkPackageInstance:
annotations = {
  "kix.dev/connections" = builtins.toJSON (map (c: {
    target = c.target.out.identityHash;
    targetName = builtins.unsafeDiscardStringContext c.target.out.name;
    port = builtins.unsafeDiscardStringContext c._resolved.port;
    protocol = c.protocol;
  }) allConnections);
};
```

### 4.4 Port Validation

The `_resolved` field already validates at declaration time — `target.out.${portName}` throws if the port doesn't exist. But we can add a better error:

```nix
_resolved = let
  port = target.out.${portName} or null;
in if port == null then
  throw "kix.connect: ${target.out.name} does not expose port '${portName}' — available: ${builtins.concatStringsSep ", " (builtins.attrNames (removeAttrs target.out ["name" "fqdn" "selector" "identityHash"]))}"
else {
  host = target.out.fqdn;
  inherit port;
};
```

### 4.5 What This Does NOT Do (Yet)

- **NetworkPolicy derivation** — this draft captures the graph. Deriving policies from it is a separate step (§5).
- **Port fan-out** — connecting a Service to an Ingress is already handled by `ingress.fromService`. Connections are about cross-package network edges, not intra-package resource wiring.
- **Protocol-level validation** — we don't verify that postgres actually speaks the postgres wire protocol on that port. We verify the port *exists*.

---

## 5. NetworkPolicy Derivation (Sketch)

Once the evaluator has connection edges for every instance, NetworkPolicy derivation becomes a cluster-level pass in `cluster.nix`:

```
For each namespace:
  1. Start with the platform's default posture (config.namespaces.*.networkPolicies)
  2. For each instance in the namespace:
     a. For each outgoing connection → add egress rule to source namespace
     b. For each incoming connection → add ingress rule to target namespace
  3. Merge derived policies with explicit policies (explicit wins on conflict)
  4. Emit as namespace-owned resources
```

The key decision: **who owns derived NetworkPolicies?**

Options:
1. **Namespace owns them** — they go into the namespace resource set alongside explicit policies. Clean ownership, but mixes manual and derived.
2. **A synthetic `network-policies` instance per namespace** — separates derived from manual. More visible, but adds instances.
3. **Source package owns egress, target package owns ingress** — matches K8s semantics, but splits one logical policy across two packages.

**Recommendation: Option 1 (namespace owns them).** The namespace already has a `networkPolicies` field. Derived policies are just more entries in that set, tagged with `kix.dev/derived: "true"` to distinguish from manual ones.

### Platform posture declaration

```nix
# In cluster module config:
{
  namespaces.production = {
    networkPolicy.defaultPosture = "deny-all";  # or "allow-same-namespace"
    # Explicit overrides still work:
    networkPolicies.allow-dns = { ... };
  };
}
```

The compiler then:
1. Emits the posture policy (deny-all ingress+egress baseline)
2. Walks all connections where source or target is in this namespace
3. Emits allow rules for each connection edge

### What the derived policy looks like

For a connection `n8n (ns: apps) → postgres (ns: data)`:

```yaml
# In namespace "apps" — egress rule
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: n8n-egress-postgres
  namespace: apps
  annotations:
    kix.dev/derived: "true"
    kix.dev/connection-source: n8n
    kix.dev/connection-target: postgres
spec:
  podSelector:
    matchLabels: <n8n's selector>
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: data
          podSelector:
            matchLabels: <postgres's selector>
      ports:
        - port: 5432
          protocol: TCP
```

```yaml
# In namespace "data" — ingress rule
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-ingress-n8n
  namespace: data
  annotations:
    kix.dev/derived: "true"
spec:
  podSelector:
    matchLabels: <postgres's selector>
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: apps
          podSelector:
            matchLabels: <n8n's selector>
      ports:
        - port: 5432
          protocol: TCP
```

Both policies derive from the single `kix.connect.tcp postgres "port" {}` declaration in n8n.

---

## 6. CLI: Connection Graph Queries

The `kix.dev/connections` annotation on PackageInstances gives the CLI the connection graph without re-evaluating Nix. The `kix graph` command extends to show connection edges:

```
$ kix graph my-cluster --connections
n8n (apps)
  ──tcp:5432──▶ postgres (data)
  ──tcp:6379──▶ valkey (data)

metabase (analytics)
  ──tcp:5432──▶ postgres (data)

postgres (data)
  ◀── n8n, metabase
```

And impact analysis for port changes:

```
$ kix impact my-cluster postgres --port 5432
Changing port 5432 on postgres (data) affects:
  - n8n (apps): connection tcp:5432, env vars DB_HOST, DB_PORT
  - metabase (analytics): connection tcp:5432
  - NetworkPolicy: postgres-ingress-n8n (data)
  - NetworkPolicy: postgres-ingress-metabase (data)
  - NetworkPolicy: n8n-egress-postgres (apps)
  - NetworkPolicy: metabase-egress-postgres (analytics)
```

This is DAG traversal — the Merkle structure already has the information, we're surfacing it through a connection-aware lens.

---

## 7. Integration with Existing Patterns

### Mounts pattern parallel

Mounts: `kix.mount.pvc resource { mountPath }` → typed object → `kix.withMounts` injects into workload.

Connections: `kix.connect.tcp target "port" { envPrefix }` → typed object → `kix.connectEnv` extracts env vars.

Both are typed constructors that produce intermediate objects consumed by an injection/extraction function.

### RBAC pattern parallel

RBAC: `rbac.reconcile ref` → intent → `rbac.grant [intents]` → merged rules → `rbac.mkRoleSet` emits resources.

Connections: `kix.connect.tcp target "port" {}` → intent → cluster pass → merged NetworkPolicies → emitted as namespace resources.

Both take high-level intent and compile down to K8s resources.

### Service/Ingress pipeline

`service.fromWorkload` and `ingress.fromService` handle intra-package resource wiring (deployment → service → ingress). Connections handle inter-package network edges. They're complementary, not overlapping.

### Compatibility with current packages

Connections are opt-in. A package that doesn't declare `connections` works exactly as before. Migration is incremental: add `connections = [...]` to a package, gain NetworkPolicy derivation and port validation, keep the manual env vars or switch to `connectEnv`.

---

## 8. Open Questions

1. **Port naming convention.** Connections reference `target.out.${portName}`. Today, packages expose ports inconsistently — some use `out.port` (singular), some name them. Should there be a standard `out.ports` attrset? Or is the flat `out.port`, `out.metricsPort` pattern sufficient?

2. **Multi-port targets.** Postgres exposes one port. But what about a package exposing both HTTP (8080) and gRPC (9090)? The connection should specify which port. Current `out` doesn't namespace ports — `out.port` is typically the primary. Do we need `out.ports.http`, `out.ports.grpc`?

3. **Connections to external services.** What about connections to things outside the cluster (external databases, SaaS APIs)? These can't be DI deps. Options: (a) ignore them, they're outside kix's control; (b) allow connections to raw host:port tuples for NetworkPolicy egress rules.

4. **Connection from non-workload resources.** CronJobs, Jobs — do they declare connections? They have pods, so NetworkPolicies apply. The connection model should work for any pod-producing resource, not just Deployments.

5. **Same-package connections.** A package with a frontend and backend deployment — does the frontend connect to the backend? This is intra-package wiring, currently handled by `service.fromWorkload`. Should connections also cover this, or is it a separate concern?

6. **Selector availability.** NetworkPolicy derivation needs `podSelector.matchLabels` for both source and target. This comes from `out.selector`. Today, `out.selector` is auto-derived by `mkResource` from `spec.selector.matchLabels`. If the target is a Helm-wrapped package, does the selector propagate correctly?

---

## 9. Incremental Implementation Plan

### Step 1: Connection constructor in compose.nix

Add `kix.connect.tcp`, `kix.connect.udp`, `kix.connect.url`, and `kix.connectEnv`. Pure functions, no evaluator changes. Packages can start using them immediately — they're just typed attrsets.

### Step 2: Collection in instance.nix

Collect `_type = "kix-connection"` objects from parts. Validate that targets are actual DI deps (not random attrsets). Store connection metadata on PackageInstance annotations.

### Step 3: Port validation

At connection construction time, validate `target.out.${portName}` exists. Throw with a helpful error listing available out fields. This is the first "compiler catches a wiring bug" moment.

### Step 4: CLI visualization

Extend `kix graph` to parse `kix.dev/connections` annotations and render connection edges. This makes the connection graph visible without any NetworkPolicy derivation.

### Step 5: NetworkPolicy derivation

Cluster-level pass in `cluster.nix` or `namespace.nix`. Walk all connections, emit ingress/egress policies per namespace, merge with explicit policies. Gated behind `networkPolicy.deriveFromConnections = true` initially.

### Step 6: Migrate existing packages

Convert n8n, metabase, python-app to use `kix.connect.*` + `kix.connectEnv`. Verify that derived NetworkPolicies match what would be hand-written. Remove manual env var construction where `connectEnv` covers it.
