# Connection Graph — Consolidated Design

**Status:** Draft
**Date:** 2026-03-26
**Supersedes:** `30_connection_graph.md` (initial exploration), `33_connection_graph_rfc.md` (prior RFC)
**Related:** `29_compiler-design.md` (sections 4.1, 4.2, 4.3), `24_package_instance_wiring.md` (DI/wiring)

---

## 1. The Problem

DI tells the compiler that package A depends on package B. But the actual network connection — "A sends TCP traffic to B on port 5432" — is invisible. It lives in hand-written env vars, URL strings, and config templates.

### 1.1 Duplicated, unvalidated internal URLs (Harbor)

Harbor has 6 internal components that reference each other via manually constructed URLs:

```nix
# harbor/default.nix — today
coreInternalURL        = "http://${name}-core:80";
registryInternalURL    = "http://${name}-registry:5000";
registryCtlInternalURL = "http://${name}-registry:8080";
```

These URLs appear 9+ times across ConfigMaps. The ports (`80`, `5000`, `8080`) are magic numbers. If the registry changes from port 5000, you grep and pray. The compiler cannot verify that `"http://${name}-registry:5000"` corresponds to a real Service with that port.

### 1.2 Hardcoded service names (Promtail)

```nix
# promtail/default.nix — today
clients = [{ url = "http://loki-gateway/loki/api/v1/push"; }];
```

The string `"loki-gateway"` is an assumption about the Loki instance's Service name. Promtail doesn't even declare Loki as a DI dependency — the connection is completely invisible to the compiler.

### 1.3 Manual host/port wiring (n8n, Immich)

```nix
# immich/default.nix — today
env = kix.mkEnvVars {
  DB_HOSTNAME = postgres.out.fqdn;
  DB_PORT     = postgres.out.port;      # manually declared output
  REDIS_HOSTNAME = valkey.out.fqdn;
  IMMICH_MACHINE_LEARNING_URL =
    "http://${machineLearning.out.fqdn}:${machineLearning.out.port}";
};
```

`DB_PORT` comes from `postgres.out.port` — which is a manually declared `outputs = { port = "5432"; }` in the postgres package. This is double bookkeeping: the Service already declares port 5432 in its spec, and the package author re-declares it in `outputs`.

### 1.4 What the compiler cannot answer today

- **Who talks to whom on which port?** (connection graph)
- **Is port 5432 actually exposed by postgres?** (port validation — only works if `out.port` is used, fails for string literals like `"6379"`)
- **What NetworkPolicies are needed?** (requires knowing all network edges)
- **What breaks if postgres changes its port?** (blast radius)

---

## 2. Core Principle: The Service Already Declares Everything

The fundamental insight: **port information should not be manually declared in `outputs`**. The Service resource already contains ports (name, number, protocol) and the pod selector. The compiler should read it from there.

Today, a package declares ports in three places:
1. Container spec: `ports = [ (kix.port "http" 8080) ]`
2. Service spec: `spec.ports` (auto-derived by `service.fromWorkload`)
3. Manual outputs: `outputs = { port = "8080"; }` ← redundant

The third is double bookkeeping. The Service already has the data.

### 2.1 Auto-derived port `out` on resources

`mkResource` for a Service should auto-derive port outputs from `spec.ports`:

```nix
service = self.deployment
  |> kix.service.fromWorkload { name = "web"; }
  |> scope.mkResource;

# Auto-derived, no manual outputs:
self.service.out.port      # → "8080" (single-port convenience)
self.service.out.ports     # → { http = "8080"; }
self.service.out.fqdn      # → "web.ns.svc.cluster.local" (already auto-derived)
self.service.out.selector  # → { ... } (already auto-derived)
```

For multi-port Services, `out.port` throws with a clear error:

```
error: Service 'web' has multiple ports — use out.ports.NAME instead
       available: http (8080), grpc (50051)
```

`out.ports` is always present. `out.port` is a single-port convenience.

### 2.2 Workload resources re-expose container ports

`mkDeployment` / `mkStatefulSet` / `mkDaemonSet` auto-derive `out.ports` from container specs:

```nix
deployment = scope.mkDeployment {
  name = "app";
  spec.template.spec.containers = [{
    name = "app";
    ports = [ (kix.port "http" 8080) (kix.port "grpc" 50051) ];
  }];
};

self.deployment.out.ports  # → { http = "8080"; grpc = "50051"; }
```

This feeds into `service.fromWorkload`, which already reads container ports. The chain flows automatically: container ports → Service ports → `out.ports`.

### 2.3 Package `out` auto-derives from main resource

`mkPackageView` already copies `out` fields from the main resource to the package view. If main is a Service:

```nix
postgres.out.port    # → "5432"
postgres.out.ports   # → { db = "5432"; }
postgres.out.fqdn    # → "postgres.data.svc.cluster.local"
```

No manual `outputs` declaration for ports. The data flows from container spec through Service spec to package `out`.

### 2.4 Named ports are required

`kix.port` already requires a name as its first argument. The design extends this: `mkDeployment` validates that all container ports have names. Unnamed ports (raw `{ containerPort = 8080; }`) are an eval-time error.

This is safe — named container ports have no negative effects in K8s. Probes can reference by name or number. Services can use named `targetPort`. The only K8s resource that requires numeric ports is Ingress `backend.service.port.number`, which references the Service port (not the container port name).

### 2.5 What stays manually declarable on `out`

`outputs` remains for non-port package API — things that aren't derivable from K8s resources:

- Builder functions: `clusterIssuer.out.withCert`
- Config values: `ingressNginx.out.ingressClassName`, `storageClasses.out.storageClassName`
- Package-specific API: `stackgresCluster.out.extensionNames`

These are package-specific interfaces that only the package author knows about. Ports are K8s-structural and should not be in this category.

---

## 3. DI Dependency = Connection (By Default)

The prior drafts (30, 33) treated connections as explicit opt-in declarations (`kix.connect.tcp postgres "port" { ... }`). This creates parallel bookkeeping — you declare the DI dep AND declare the connection AND write the env vars.

**The new model:** every DI dependency is a connection by default. If the target has a Service with ports, the compiler assumes the source connects to it. The package author opts out of exceptions.

### 3.1 How the compiler determines connections

```
For each instance A with DI dep B:
  1. Does B expose out.ports (non-empty)?
     → No:  no connection. B is infrastructure (CRDs, storage classes, etc.)
     → Yes: connection edge A → B, covering all ports in B.out.ports

  2. Does A declare meta.connections.B = false?
     → Yes: remove the edge (package author says "I don't connect to this")

  3. Does A declare meta.connections.B = { ports = [...]; }?
     → Yes: restrict edge to only those named ports
```

### 3.2 Why the default works

Looking at real DI deps across the codebase:

| DI dep | Has Service ports? | Actually connects? | Default correct? |
|---|---|---|---|
| `postgres` | Yes (`5432`) | Yes | Yes |
| `valkey` | Yes (`6379`) | Yes | Yes |
| `machineLearning` | Yes | Yes | Yes |
| `clusterIssuer` | No (exposes `withCert`) | No | Yes |
| `storageClass` | No (exposes `storageClassName`) | No | Yes |
| `ingressNginx` | No primary port (exposes `ingressClassName`) | No | Yes |

Packages that expose Services are overwhelmingly connected-to by their consumers. Packages that expose builder functions / config values don't have Services. The heuristic — "has `out.ports`" — is correct for every current package.

The rare exception: a package that DI-depends on a Service-exposing dep but doesn't connect (e.g., a dashboard that shows postgres's hostname without sending traffic). The package author handles this with `meta.connections.postgres = false`.

### 3.3 Package-side opt-out (not cluster-side)

The package author knows whether their code connects to a dependency. This is a property of the package's implementation, not a cluster configuration concern.

```nix
# monitoring-dashboard/default.nix
{ scope, kix, postgres, valkey, ... }:
{
  meta = {
    connections = {
      postgres = false;  # I display its status, I don't query it
      valkey = false;
    };
  };
  # ...
}
```

The `meta.connections` field is only needed for exceptions. Most packages declare nothing.

### 3.4 Multi-port restriction

When a dep exposes multiple ports and the consumer only needs some:

```nix
# consumer/default.nix
{ scope, kix, weaviate, ... }:
{
  meta = {
    connections = {
      weaviate = { ports = [ "http" ]; };  # I only use HTTP, not gRPC
    };
  };
}
```

If omitted, the connection includes all ports. The compiler uses this for NetworkPolicy: only the declared (or defaulted) ports get allow rules.

---

## 4. Platform Services: The Inverse Connection Problem

The DI-based connection graph handles app-to-app connections. But some services connect to things they don't DI-depend on:

- **Prometheus** scrapes metrics from every instrumented service. The targets don't depend on prometheus. Prometheus doesn't DI-depend on each target.
- **Ingress controllers** route traffic to Services referenced by Ingress resources. The DI relationship is inverted — the app depends on the ingress controller, but the traffic flows the other way.

These are **platform services** that need broad network access. The connection model from §3 doesn't cover them — and shouldn't try to. They're a cluster-operator concern, not a package-author concern.

### 4.1 Instance-level `connectsTo`

A cluster-operator mechanism for granting an instance network access beyond its DI deps:

```nix
# cluster module
instances.monitoring.prometheus = {
  package = packages.kube-prometheus-stack;
  connectsTo = {
    # Allow egress to any instance that exposes a "metrics" port
    metricsTargets = { port = "metrics"; };
  };
};
```

The evaluator walks all instances, finds those with `out.ports.metrics`, and derives:
- Egress rules from prometheus to each target on the metrics port
- Ingress rules on each target allowing prometheus

This is distinct from DI — it doesn't inject dependencies, it just creates network edges. The cluster operator controls it because they know which monitoring stack is deployed and what access it needs.

### 4.2 Namespace-level policy override

For cases where precise connection modeling isn't worth it:

```nix
namespaces.monitoring = {
  networkPolicy.egress = "allow-all";
};
```

This is a raw policy escape hatch. It doesn't participate in the connection graph — it just overrides NetworkPolicy for the namespace. Useful for platform namespaces where broad access is expected.

### 4.3 Ingress controller connections

Ingress controllers are a special case: the compiler CAN derive their connections from Ingress resources. Every Ingress resource references a backend Service — the compiler knows the ingress controller needs to reach that Service.

This is a compiler pass, not a package or cluster-operator concern:

```
For each Ingress resource in the cluster:
  source = the ingress controller instance (known from ingressClassName)
  target = the backend Service
  port = the backend port number
  → derive NetworkPolicy edge
```

This is future work but follows naturally from the connection model.

---

## 5. NetworkPolicy Derivation

Once the compiler has connection edges from §3 (DI-derived) and §4 (platform-service), it derives NetworkPolicies.

### 5.1 Platform posture

```nix
# cluster module
namespaces.production = {
  networkPolicy = {
    defaultPosture = "deny-all";
    deriveFromConnections = true;
  };
};
```

The compiler emits:
1. A baseline deny-all policy (posture)
2. An allow rule for each connection edge involving this namespace

### 5.2 Derived policy shape

For a connection `n8n (ns: apps) → postgres (ns: data)` on port 5432:

```yaml
# In namespace "apps" — egress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: n8n-egress-postgres
  namespace: apps
  annotations:
    kix.dev/derived: "true"
spec:
  podSelector:
    matchLabels: <n8n's workload selector>
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: data }
          podSelector:
            matchLabels: <postgres's Service selector>
      ports:
        - port: 5432
          protocol: TCP

# In namespace "data" — ingress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-ingress-n8n
  namespace: data
  annotations:
    kix.dev/derived: "true"
spec:
  podSelector:
    matchLabels: <postgres's Service selector>
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: apps }
          podSelector:
            matchLabels: <n8n's workload selector>
      ports:
        - port: 5432
          protocol: TCP
```

All data comes from existing resources:
- Source pod selector: workload's `spec.selector.matchLabels`
- Target pod selector: Service's `spec.selector`
- Ports + protocols: Service's `spec.ports`
- Namespaces: from instance evaluation context

### 5.3 Ownership

Derived policies are **namespace-owned** — they sit alongside explicit namespace policies in `namespace.nix`. Tagged with `kix.dev/derived: "true"` to distinguish from manual ones. Manual policies take precedence on conflict.

---

## 6. Env Var Wiring

The connection graph (§3, §4) handles NetworkPolicy and port validation. Env var wiring is a separate concern — the package still controls how it consumes a dependency's connection info.

### 6.1 Current state (no change needed)

Packages read `out` fields and construct env vars:

```nix
env = kix.mkEnvVars {
  DB_HOST = postgres.out.fqdn;
  DB_PORT = postgres.out.port;     # auto-derived from Service, not manual outputs
  REDIS_HOST = valkey.out.fqdn;
  REDIS_PORT = valkey.out.port;
};
```

The key improvement from §2: `out.port` is now auto-derived from the Service spec, not from manual `outputs`. The package author no longer declares `outputs = { port = "5432"; }` — it comes for free from the Service.

### 6.2 Why not auto-generate env vars?

Earlier drafts (30, 33) explored `kix.connect.tcp target "port" { envPrefix = "DB"; }` to auto-generate `DB_HOST` and `DB_PORT`. We dropped this because:

- Env var naming is package-specific: Immich uses `DB_HOSTNAME`, n8n uses `DB_POSTGRESDB_HOST`
- URL formats vary: some want `host:port`, others want `redis://host:port/0?idle_timeout=30`
- Config injection isn't always env vars — some use YAML templates, CLI args, config files

The connection graph's job is **NetworkPolicy derivation and port validation**. Env var wiring stays with the package author, but becomes simpler because `out.port` / `out.ports` are auto-derived and validated.

### 6.3 Port validation for free

Since `out.port` and `out.ports` are auto-derived from the Service spec, any consumer accessing `postgres.out.port` gets a validated port number. If postgres's Service changes its port, `out.port` changes, and Nix's lazy evaluation propagates the change through all consumers (hash changes, blast radius visible in the DAG).

If a consumer accesses `weaviate.out.ports.grpc` and the `grpc` port is removed from weaviate's Service, the eval fails with a clear error — at build time, not at runtime.

---

## 7. Implementation in lib/

### 7.1 `compose.nix`: `kix.port` (no change)

Already requires named ports. No changes needed.

```nix
port = name: containerPort: { inherit name containerPort; protocol = "TCP"; };
```

### 7.2 `k8s.nix` / `scope.nix`: Auto-derive `out.ports` on resources

**Workloads** (`mkDeployment`, `mkStatefulSet`, `mkDaemonSet`):
- Read `spec.template.spec.containers[*].ports`
- Validate all ports have names (throw if unnamed)
- Populate `out.ports = { portName = "portNumber"; ... }`

**Services** (`mkResource` when `kind == "Service"`):
- Read `spec.ports`
- Populate `out.ports = { portName = "servicePortNumber"; ... }`
- Populate `out.port`:
  - Single port → the port number as string
  - Multiple ports → a thunk that throws with available port names
  - Zero ports → not set

**All other kinds**: no `out.ports`.

### 7.3 `compose.nix`: `service.fromWorkload` changes

Remove `outputs` for port-related fields. The auto-derivation in `mkResource` handles it:

```nix
# Before:
autoOutputs = lib.optionalAttrs (firstPort != null) { port = firstPort; };
# ...
outputs = autoOutputs // (cfg.outputs or {});

# After:
# No port-related outputs. mkResource auto-derives out.ports from spec.ports.
# Non-port outputs (if any) still passed through.
```

### 7.4 `instance.nix`: Connection graph collection

After building parts, the evaluator derives the connection graph:

```nix
# Collect connection edges from DI deps
connectionEdges =
  let
    depInstances = /* resolved DI deps for this instance */;
    packageConnOverrides = packageMeta.connections or {};
  in
  lib.foldlAttrs (acc: depName: depInst:
    let
      override = packageConnOverrides.${depName} or null;
      targetPorts = depInst.out.ports or {};
    in
    # Skip if: no ports on target, or explicitly opted out
    if targetPorts == {} then acc
    else if override == false then acc
    else
      let
        ports =
          if override != null && override ? ports
          then lib.filterAttrs (n: _: builtins.elem n override.ports) targetPorts
          else targetPorts;
      in
      acc ++ [{
        target = depName;
        targetInstance = depInst;
        inherit ports;
      }]
  ) [] depInstances;
```

Store on PackageInstance annotation:

```nix
annotations."kix.dev/connections" = builtins.toJSON (map (edge: {
  target = builtins.unsafeDiscardStringContext edge.targetInstance.out.name;
  targetIdentityHash = builtins.unsafeDiscardStringContext edge.targetInstance.out.identityHash;
  ports = lib.mapAttrsToList (name: number: {
    inherit name;
    number = builtins.fromJSON (builtins.unsafeDiscardStringContext number);
    protocol = "TCP";  # or read from Service spec
  }) edge.ports;
}) connectionEdges);
```

### 7.5 `cluster.nix` / `namespace.nix`: NetworkPolicy derivation

A cluster-level pass after all instances are evaluated:

```
For each namespace with deriveFromConnections = true:
  1. Emit baseline posture policy (deny-all)
  2. For each instance in the cluster with connection edges:
     For each edge where source OR target is in this namespace:
       Emit allow rule (egress on source side, ingress on target side)
  3. For each instance with connectsTo declarations:
     Walk matching targets, emit allow rules
  4. Merge with explicit namespace policies (explicit wins)
```

### 7.6 `modules.nix`: New options

```nix
# On instance submodule:
connectsTo = lib.mkOption {
  type = lib.types.attrsOf (lib.types.submodule {
    options.port = lib.mkOption { type = lib.types.str; };
  });
  default = {};
  description = "Platform-level connections beyond DI deps (e.g., prometheus → metrics ports).";
};

# On namespace submodule:
networkPolicy.defaultPosture = lib.mkOption {
  type = lib.types.enum [ "deny-all" "allow-same-namespace" "allow-all" ];
  default = "allow-all";
};
networkPolicy.deriveFromConnections = lib.mkOption {
  type = lib.types.bool;
  default = false;
};
```

---

## 8. CLI

### 8.1 Connection graph visualization

`kix.dev/connections` annotations on PackageInstances give the CLI the connection graph without re-evaluating Nix:

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

### 8.2 Impact analysis

```
$ kix impact my-cluster postgres
Changing postgres (data) affects:
  connections:
    n8n (apps) → tcp:5432
    metabase (analytics) → tcp:5432
  derived NetworkPolicies:
    postgres-ingress-n8n (data)
    postgres-ingress-metabase (data)
    n8n-egress-postgres (apps)
    metabase-egress-postgres (analytics)
```

---

## 9. Concrete Example: Before and After

### Before (current)

```nix
# packages/immich/default.nix
{ scope, kix, postgres, valkey, machineLearning ? null, ... }:
{
  options = { /* ... */ };
  build = { self, config, ... }:
  let
    hasMl = machineLearning != null;
  in {
    deployment = scope.mkDeployment {
      name = "server";
      spec.template.spec.containers = [{
        name = "server";
        ports = [ (kix.port "http" 2283) ];
        env = kix.mkEnvVars {
          DB_HOSTNAME = postgres.out.fqdn;
          DB_PORT     = postgres.out.port;     # manual outputs on postgres
          REDIS_HOSTNAME = valkey.out.fqdn;
          IMMICH_MACHINE_LEARNING_URL =
            if hasMl
            then "http://${machineLearning.out.fqdn}:${machineLearning.out.port}"
            else null;
        };
      }];
    };

    service = self.deployment
      |> kix.service.fromWorkload { name = "server"; }
      |> scope.mkResource;

    main = self.service;
  };
}

# packages/stackgres-cluster/default.nix (target)
outputs = { port = "5432"; serviceName = "..."; };  # manual
```

### After (new design)

```nix
# packages/immich/default.nix
{ scope, kix, postgres, valkey, machineLearning ? null, ... }:
{
  options = { /* ... */ };
  build = { self, config, ... }:
  let
    hasMl = machineLearning != null;
  in {
    deployment = scope.mkDeployment {
      name = "server";
      spec.template.spec.containers = [{
        name = "server";
        ports = [ (kix.port "http" 2283) ];
        env = kix.mkEnvVars {
          DB_HOSTNAME = postgres.out.fqdn;
          DB_PORT     = postgres.out.port;     # auto-derived from postgres's Service
          REDIS_HOSTNAME = valkey.out.fqdn;
          IMMICH_MACHINE_LEARNING_URL =
            if hasMl
            then "http://${machineLearning.out.fqdn}:${machineLearning.out.port}"
            else null;
        };
      }];
    };

    service = self.deployment
      |> kix.service.fromWorkload { name = "server"; }
      |> scope.mkResource;

    main = self.service;
  };
}
# No meta.connections needed — all three deps have Services, all are genuine connections.
# Connection graph: immich → postgres (5432), immich → valkey (6379),
#                   immich → machineLearning (port) [when present]
# NetworkPolicies: auto-derived from these edges.

# packages/stackgres-cluster/default.nix (target)
# outputs = { port = "5432"; };  ← GONE. out.port auto-derived from Service spec.
# out.serviceName etc. remain if they're non-port API.
```

The package code barely changes. The difference is:
1. `out.port` on the target is auto-derived (no manual `outputs`)
2. The connection graph is derived from DI edges (no explicit `connections` declaration)
3. NetworkPolicies are derived from the connection graph (no manual policies for app-to-app traffic)

---

## 10. Migration Path

### Step 1: Auto-derive `out.ports` / `out.port` on Service resources

Change `mkResource` (for Services) and `mkDeployment` (for workloads) to auto-populate port outputs from specs. Remove manual `outputs = { port = ... }` from packages that use `service.fromWorkload`. Validate named ports on workloads.

This is a lib-only change. Package output YAML is identical. The only difference is how `out.port` gets its value.

### Step 2: Connection graph collection in `instance.nix`

Derive connection edges from DI deps + `out.ports` presence. Store on PackageInstance annotations. Add `meta.connections` support for opt-out / port restriction. No package changes needed — the defaults are correct.

### Step 3: CLI visualization

Extend `kix graph` to parse `kix.dev/connections` and render connection edges. This makes the graph visible and validates the derived edges against expectations.

### Step 4: NetworkPolicy derivation

Cluster-level pass in `namespace.nix`. Gate behind `networkPolicy.deriveFromConnections = true`. Compare derived policies against hand-written ones. Add `connectsTo` for platform services (prometheus).

### Step 5: Remove manual port outputs across packages

Audit all packages for `outputs = { port = ... }`. Remove where the Service auto-derivation covers it. Keep non-port outputs (`withCert`, `ingressClassName`, etc.).

---

## 11. Open Questions

1. **Intra-package connections (Harbor).** Harbor's 6 components talk to each other within a single package. The DI-based model doesn't cover this — there's no DI edge between `self.core` and `self.registry`. Options: (a) out of scope, intra-package wiring uses `self.*.out` as today; (b) extend the model to support `self` connections. Leaning toward (a) — intra-package wiring is already partially solved by `service.fromWorkload` and `out.fqdn`.

2. **External connections.** Connections to services outside the cluster (managed databases, SaaS APIs) can't be DI deps. Options: (a) out of scope, handle with manual NetworkPolicy; (b) `connectsTo.external = { host = "rds.amazonaws.com"; port = 5432; }` for egress rules. Leaning toward (a) for now.

3. **CronJobs and Jobs.** These produce pods and have network behavior. They have workload selectors. The connection model should work for any pod-producing resource. Need to verify that `mkResource` handles Job/CronJob port extraction correctly (they don't have `spec.selector.matchLabels` the same way).

4. **Helm-wrapped packages.** `fromHelmChart` auto-selects main as `Service > Deployment > ...`. If main is a Service, `out.ports` auto-derives from its spec. Helm charts with unnamed ports get a validation warning. The package author can add names when wrapping. Need to verify this works with the `wrapHelmResource` flow.

5. **`connectsTo` granularity.** For prometheus: `connectsTo.metricsTargets = { port = "metrics"; }` walks all instances looking for `out.ports.metrics`. Is this the right API? Should it support namespace filters? Label selectors? How complex does this need to be vs. just using raw namespace-level policy overrides?

6. **Port protocol.** `kix.port` defaults to TCP. Services can have UDP ports (coredns uses both). The auto-derivation should carry protocol through. Need to verify `service.fromWorkload` preserves protocol from container ports to Service ports.

7. **Port remapping.** `service.fromWorkload` can remap ports (Service port 80 → container targetPort 3000). `out.port` should expose the Service port (what consumers connect to), not the container port. The NetworkPolicy should use the targetPort (what the pod listens on). Need to handle this distinction correctly.

8. **Selector availability.** NetworkPolicy derivation needs `out.selector` on both source and target. For the target, this comes from the Service's `spec.selector`. For the source, it comes from the workload's `spec.selector.matchLabels`. Both are already auto-derived. Need to verify this works for Helm-wrapped packages where selectors may use non-standard labels.
