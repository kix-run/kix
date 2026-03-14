# Dependency Injection, Environments, and DNS-Like Resolution

## Working Document — March 2026

**Status:** Design exploration (not yet implemented)
**Predecessor:** `02_kixpkgs-design-doc.md` (manual wiring via `config.instances.*`)

---

## 1. The Goal

Packages declare what they need by argument name. The system finds the right instance automatically, using a resolution strategy that mirrors Kubernetes DNS: namespace-local first, then cluster-wide. No manual `config.instances.postgres` wiring unless you want to override.

This document also explores environment/namespace ergonomics and a DSL for expressing dev/prod variants concisely.

---

## 2. DNS-Like Resolution

### 2.1 The Principle

K8s DNS resolves `postgres` to `postgres.<my-namespace>.svc.cluster.local` first, then falls back depending on search domains. Build-time resolution should work the same way, so that what the evaluator picks matches what the runtime DNS would resolve.

### 2.2 Resolution Order

For an instance in namespace `production` requesting `postgres`:

```
1. postgres in namespace "production", reachable?     → use it
2. postgres unique cluster-wide, reachable?           → use it
3. postgres exists but all unreachable (NetworkPolicy) → error with explanation
4. multiple reachable candidates                      → error: ambiguous, specify explicitly
5. no postgres anywhere                               → error: no instance available
```

"Reachable" means: the target namespace's NetworkPolicies allow ingress from the requesting namespace. When no NetworkPolicies exist in the target namespace, it's considered reachable (K8s default: allow all).

### 2.3 Match Key

Resolution matches on **package type**, not instance name. A service declared as:

```nix
services.analytics-db = { package = "postgres"; namespace = "data"; };
```

...satisfies a `postgres` argument. The package type is `cfg.package or cfg.name` — defaulting to the attribute name when no explicit `package` is set.

### 2.4 Package Function Signature

```nix
# kixpkgs/my-app.nix
# "postgres" and "valkey" are resolved automatically.
# "scope" and "config" are always injected by the system.
{ scope, config, postgres, valkey }:

in self: {
  deployment = scope.mkResource {
    # ...
    env = [{
      name = "DATABASE_URL";
      value = scope.str [ "postgresql://" postgres.fqdn ":" postgres.out.port "/mydb" ];
    } {
      name = "REDIS_URL";
      value = scope.str [ "redis://" valkey.fqdn ":" valkey.out.port ];
    }];
  };
  # ...
}
```

### 2.5 Explicit Override Always Wins

```nix
services.my-app = {
  namespace = "production";
  postgres = instances.special-postgres;  # skip resolution, use this
  # valkey still auto-resolved
};
```

### 2.6 Opt-Out

```nix
{
  cluster.autoResolve = true;           # cluster default

  services.sensitive-app = {
    autoResolve = false;                 # all deps must be explicit
    postgres = instances.prod-db;        # required
    valkey = instances.prod-cache;       # required
  };
}
```

When `autoResolve = false`, any unspecified dependency argument is a hard eval error.

---

## 3. Reachability Checking

### 3.1 Why

NetworkPolicy misconfigurations are the most common "works in dev, breaks in prod" issue. The system has enough information at eval time to catch these.

### 3.2 What We Check

The evaluator collects all NetworkPolicy resources in the target namespace (they're already in the DAG — namespaces carry their policies via `requires`). For each auto-resolved dependency:

- If target namespace has no NetworkPolicies → reachable (K8s default-allow)
- If any ingress rule allows traffic from the requesting namespace → reachable
- Otherwise → unreachable

### 3.3 Error Quality

```
error: my-app (ns: production) needs 'postgres', found but unreachable:

  analytics-db (ns: data) — blocked by NetworkPolicy "data-netpol-0"
    Ingress allowed from: [monitoring, data]
    Requesting namespace: production

  Hint: Add an ingress rule for "production" in namespaces.data.networkPolicies,
        or specify an explicit override: services.my-app.postgres = instances.<name>;
```

This is something no K8s tool provides today. Everyone discovers NetworkPolicy issues at runtime.

### 3.4 Limits

Reachability checking is best-effort. Complex selectors (label-based pod selectors, CIDR blocks, Cilium policies) may not be fully evaluable at build time. The system should:

- Check what it can (namespace selectors — covers most cases)
- Skip what it can't (label-based pod selectors) with a note
- Never false-positive block a valid deploy

---

## 4. Environment and Namespace DSL

### 4.1 The Problem

Real clusters have repeating structure: dev and prod run the same services with different configs. Namespaces group related services. The DSL should make this structure obvious and concise, not force you to repeat yourself.

### 4.2 Namespace Blocks

Namespaces are first-class grouping constructs. Services declared inside a namespace block inherit that namespace — no need to specify it per-service.

```nix
{
  namespaces.frontend = {
    # Namespace-level config (policies, quotas)
    resourceQuota.hard."requests.cpu" = "10";

    # Services in this namespace
    services.web-app = {
      image = "webapp:v2.1.0";
      replicas = 3;
    };
  };

  namespaces.backend = {
    services.api = {
      image = "api:v1.5.0";
      replicas = 3;
    };

    services.valkey = {
      # namespace-local cache, only reachable from backend
      package = "valkey";
    };
  };

  namespaces.data = {
    resourceQuota.hard."requests.storage" = "500Gi";

    services.postgres = { storage = "100Gi"; };
    services.valkey = { sentinel.enabled = true; };
  };
}
```

Note: two `valkey` instances — one in `backend` (local cache), one in `data` (shared). DNS-like resolution means:

- `api` (in `backend`) requesting `valkey` → finds `valkey.backend` (same namespace)
- `web-app` (in `frontend`) requesting `valkey` → ambiguous (two exist), must specify or rely on reachability to filter

### 4.3 Environment Variants

An environment is a function from a base service set to a modified one. Like overlays but with a focused purpose: expressing dev/prod differences.

```nix
# clusters/base.nix — shared structure
{
  namespaces.frontend.services.web-app = {
    image = "webapp:v2.1.0";
  };

  namespaces.backend = {
    services.api = {
      image = "api:v1.5.0";
    };
    services.valkey = {
      package = "valkey";
    };
  };

  namespaces.data = {
    services.postgres = { storage = "100Gi"; };
    services.valkey = { sentinel.enabled = true; };
  };
}
```

```nix
# clusters/production.nix
{ base }:
base.withEnvironment {
  name = "prod";

  cluster.labels."env" = "production";

  # Per-namespace overrides
  namespaces.frontend = {
    networkPolicies = [{ /* lock down ingress */ }];
    services.web-app.replicas = 5;
  };

  namespaces.backend = {
    services.api.replicas = 5;
  };

  namespaces.data = {
    resourceQuota.hard."requests.storage" = "1Ti";
    services.postgres.storage = "500Gi";
  };
}
```

```nix
# clusters/dev.nix
{ base }:
base.withEnvironment {
  name = "dev";

  cluster.labels."env" = "dev";

  # Global default: 1 replica unless overridden
  defaults.replicas = 1;

  namespaces.data = {
    services.postgres.storage = "10Gi";
  };
}
```

### 4.4 How `withEnvironment` Works

```nix
withEnvironment = envConfig:
  let
    # Deep merge: env overrides win, base provides defaults
    merged = lib.recursiveUpdate baseConfig envConfig;

    # Apply defaults to all services that don't specify the value
    withDefaults = applyDefaults merged (envConfig.defaults or {});
  in buildCluster withDefaults;
```

The key property: `base.nix` is the single source of truth for *what services exist and how they're connected*. Environment files only say *how this environment differs*. Add a new service to base → it appears in all environments.

### 4.5 Flat Services Alongside Namespace Blocks

Sometimes you want to reference a service that lives in a namespace you don't "own" (e.g., kube-system). Top-level `services` still work and require an explicit namespace:

```nix
{
  # Namespace block — owns the namespace, defines policies
  namespaces.backend = {
    services.api = { /* ... */ };
  };

  # Top-level service — lives in a namespace defined elsewhere
  services.coredns = {
    namespace = "kube-system";
  };
}
```

The evaluator merges both forms. If a namespace is referenced by a service but has no namespace block, a bare namespace (no policies) is created.

---

## 5. Worked Example: Web App + Backend + Data

A concrete cluster with:
- **frontend** namespace: `web-app` (React SPA + BFF)
- **backend** namespace: `api` (Go service), `valkey` (namespace-local response cache)
- **data** namespace: `postgres` (primary DB), `valkey` (shared session store)
- Dev and prod variants

### 5.1 Package Definitions

```nix
# kixpkgs/web-app.nix
# Depends on api backend. Resolved automatically.
{ scope, config, api }:

in self: {
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = scope.instanceName;
    spec = {
      replicas = config.replicas or 1;
      template.spec.containers = [{
        name = "web";
        image = config.image;
        env = [{
          name = "API_URL";
          # api is in a different namespace → fqdn resolves cross-namespace
          # auto-tracked dep on api, which pulls in backend namespace
          value = scope.str [ "http://" api.fqdn "/api" ];
        }];
      }];
    };
  };

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = scope.instanceName;
    spec.ports = [{ port = 80; targetPort = 3000; }];
    outputs = { port = 80; };
  };

  main = self.service // { requires = [ self.deployment ]; };
}
```

```nix
# kixpkgs/api.nix
# Depends on postgres (DB) and valkey (cache).
# Resolution:
#   valkey → finds valkey.backend (same namespace, local cache)
#   postgres → finds postgres.data (only postgres in cluster)
{ scope, config, postgres, valkey }:

in self: {
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = scope.instanceName;
    spec = {
      replicas = config.replicas or 1;
      template.spec.containers = [{
        name = "api";
        image = config.image;
        env = [
          {
            name = "DATABASE_URL";
            value = scope.str [
              "postgresql://" postgres.fqdn ":" postgres.out.port "/mydb"
            ];
          }
          {
            name = "CACHE_URL";
            # valkey.backend — same namespace, no fqdn needed, but fqdn works too
            value = scope.str [
              "redis://" valkey.fqdn ":" valkey.out.port
            ];
          }
          {
            # Hypothetical: also talk to the shared session valkey.
            # This CAN'T be auto-resolved (two valkeys reachable),
            # so it must be explicit in the cluster config if needed.
            # See section 5.2 for how this is handled.
          }
        ];
      }];
    };
  };

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = scope.instanceName;
    spec.ports = [{ port = 80; targetPort = 8080; }];
    outputs = { port = 80; };
  };

  capabilities.monitoring = {
    endpoints = [{ port = "metrics"; interval = "15s"; }];
    serviceLabels = self.labels;
  };

  main = self.service // { requires = [ self.deployment ]; };
}
```

### 5.2 Cluster Base Config

```nix
# clusters/base.nix
{
  namespaces.frontend = {
    services.web-app = {
      image = "webapp:v2.1.0";
      # "api" dep resolved automatically:
      #   1. api in frontend? No.
      #   2. api cluster-wide unique? Yes → api.backend
    };
  };

  namespaces.backend = {
    services.api = {
      image = "api:v1.5.0";
      # "postgres" dep → postgres.data (only one in cluster)
      # "valkey" dep → valkey.backend (same namespace wins)
    };

    services.valkey = {
      # This IS the namespace-local cache.
      # No sentinel, no persistence — ephemeral response cache.
      package = "valkey";
      persistence.enabled = false;
      maxmemory = "256Mi";
      eviction = "allkeys-lru";
    };
  };

  namespaces.data = {
    services.postgres = {
      storage = "100Gi";
      version = "16";
    };

    services.valkey = {
      # Shared session/queue store.
      # Sentinel for HA, persistence on.
      package = "valkey";
      sentinel.enabled = true;
      persistence.enabled = true;
    };
  };
}
```

### 5.3 Resolution Trace

What the evaluator does with `api` in namespace `backend`:

```
api needs "postgres":
  1. postgres in backend?  → no
  2. postgres cluster-wide → postgres.data (unique) ✓
  Resolved: postgres.data

api needs "valkey":
  1. valkey in backend?    → yes: valkey.backend ✓
  Resolved: valkey.backend
  (valkey.data also exists but same-namespace wins — never even considered)

web-app needs "api":
  1. api in frontend?      → no
  2. api cluster-wide      → api.backend (unique) ✓
  Resolved: api.backend
```

### 5.4 Production Environment

```nix
# clusters/production.nix
{ base }:
base.withEnvironment {
  name = "prod";
  cluster.labels."env" = "production";

  namespaces.frontend = {
    resourceQuota.hard = {
      "requests.cpu" = "10";
      "limits.memory" = "32Gi";
    };
    networkPolicies = [{
      # Only allow ingress from ingress controller namespace
      podSelector = {};
      policyTypes = [ "Ingress" ];
      ingress = [{
        from = [{ namespaceSelector.matchLabels."app" = "ingress"; }];
      }];
    }];

    services.web-app.replicas = 5;
  };

  namespaces.backend = {
    networkPolicies = [{
      # Allow ingress from frontend and monitoring only
      podSelector = {};
      policyTypes = [ "Ingress" ];
      ingress = [{
        from = [
          { namespaceSelector.matchLabels."env/ns" = "frontend"; }
          { namespaceSelector.matchLabels."app" = "monitoring"; }
        ];
      }];
    }];

    services.api.replicas = 5;
    # valkey.backend inherits base config, 1 replica is fine for cache
  };

  namespaces.data = {
    resourceQuota.hard."requests.storage" = "1Ti";
    networkPolicies = [{
      # Allow ingress from backend only
      podSelector = {};
      policyTypes = [ "Ingress" ];
      ingress = [{
        from = [{ namespaceSelector.matchLabels."env/ns" = "backend"; }];
      }];
    }];

    services.postgres.storage = "500Gi";
  };

  monitoring.enabled = true;
}
```

### 5.5 Dev Environment

```nix
# clusters/dev.nix
{ base }:
base.withEnvironment {
  name = "dev";
  cluster.labels."env" = "dev";

  # Global: 1 replica for everything
  defaults.replicas = 1;

  namespaces.data = {
    # Small storage for dev
    services.postgres.storage = "10Gi";
  };

  # No network policies in dev — everything can talk to everything
  # No resource quotas — dev clusters are small anyway
}
```

### 5.6 Resulting DAGs

**Production — `web-app` closure:**

```
Service/web-app (ns: frontend)
├─ dep → Namespace/frontend
│         ├─ req → ResourceQuota/frontend-quota
│         └─ req → NetworkPolicy/frontend-netpol-0
│
└─ req → Deployment/web-app (ns: frontend)
          └─ dep → Service/api (ns: backend)          ← cross-namespace via fqdn
                    ├─ dep → Namespace/backend
                    │         └─ req → NetworkPolicy/backend-netpol-0
                    │
                    └─ req → Deployment/api (ns: backend)
                              ├─ dep → Service/postgres (ns: data)    ← cross-ns
                              │         ├─ dep → Namespace/data
                              │         │         ├─ req → ResourceQuota/data-quota
                              │         │         └─ req → NetworkPolicy/data-netpol-0
                              │         └─ req → StatefulSet/postgres
                              │
                              └─ dep → Service/valkey (ns: backend)   ← same-ns
                                        └─ req → Deployment/valkey
```

**Reachability check catches:**

If someone later adds a NetworkPolicy to `data` that only allows ingress from `data` itself:

```
error: api (ns: backend) needs 'postgres', found but unreachable:

  postgres (ns: data) — blocked by NetworkPolicy "data-netpol-0"
    Ingress allowed from: [data]
    Requesting namespace: backend

  Hint: Add "backend" to the ingress rules in namespaces.data.networkPolicies,
        or override: namespaces.backend.services.api.postgres = instances.<name>;
```

### 5.7 What the User Typed vs What They'd Type in Helm

**kixpkgs (base.nix — the part that matters):**

```nix
namespaces.frontend.services.web-app.image = "webapp:v2.1.0";
namespaces.backend.services.api.image = "api:v1.5.0";
namespaces.backend.services.valkey = { package = "valkey"; persistence.enabled = false; };
namespaces.data.services.postgres = { storage = "100Gi"; };
namespaces.data.services.valkey = { package = "valkey"; sentinel.enabled = true; };
```

5 lines. All wiring is automatic. Add `replicas = 5` in the prod overlay and you're done.

**Helm equivalent** for the same setup: 5 charts, 5 values files (minimum), manual namespace creation, no cross-chart dependency tracking, no deploy ordering, no reachability checking, and a bash script to apply them in the right order.

---

## 6. Implementation Sketch: `kixCallPackage`

```nix
kixCallPackage = packageFn: instanceConfig: explicitDeps:
  let
    fnArgs = builtins.functionArgs packageFn;
    depArgNames = attrNames (removeAttrs fnArgs [ "scope" "config" "lib" ]);

    myNs = instanceConfig.namespace;

    # All instances indexed by package type
    byType = groupBy (inst: inst.package or inst.name) allInstances;

    resolve = argName:
      let
        candidates = byType.${argName} or [];
        sameNs = filter (c: c.namespace == myNs) candidates;
        reachable = filter (c: isReachable myNs c.namespace) candidates;
        sameNsReachable = filter (c: c.namespace == myNs) reachable;
      in
        if length sameNsReachable == 1 then head sameNsReachable
        else if length sameNs > 1 then
          throw "${instanceConfig.name}: multiple '${argName}' in namespace ${myNs} — specify explicitly"
        else if length reachable == 1 then head reachable
        else if candidates != [] && reachable == [] then
          throw "${instanceConfig.name}: '${argName}' exists but unreachable (NetworkPolicy)"
        else if length reachable > 1 then
          throw "${instanceConfig.name}: multiple reachable '${argName}' — specify explicitly"
        else throw "${instanceConfig.name}: no '${argName}' in cluster";

    autoResolved =
      if instanceConfig.autoResolve or clusterConfig.autoResolve or true
      then genAttrs depArgNames resolve
      else {};  # all deps must come from explicitDeps

    unresolved = subtractLists (attrNames (autoResolved // explicitDeps)) depArgNames;
    _ = assert unresolved == [] ||
      throw "${instanceConfig.name}: unresolved deps: ${toString unresolved}";

  in packageFn ({
    scope = mkScope instanceConfig;
    config = instanceConfig;
  } // autoResolved // explicitDeps);  # explicit always wins
```

---

## 7. The `buildCluster` Evaluator with Namespace Blocks

```nix
buildCluster = clusterConfig:
  let
    # 1. Collect all services from namespace blocks + top-level
    allServices = collectServices clusterConfig;
    # Result: { "frontend/web-app" = { package="web-app"; namespace="frontend"; ... }; ... }

    # 2. Build namespace resources with policies
    namespaceResources = mapAttrs (name: nsCfg:
      k8s.mkNamespace {
        inherit name;
        inherit (nsCfg) resourceQuota limitRange networkPolicies;
        labels = clusterConfig.cluster.labels // { "env/ns" = name; };
      }
    ) clusterConfig.namespaces;

    # 3. Outer fixpoint: all instances see each other
    instances = lib.fix (self:
      mapAttrs (qualifiedName: svcCfg:
        let
          pkg = loadPackage svcCfg.package or svcCfg.name;
          scope = mkScope svcCfg namespaceResources.${svcCfg.namespace};
          explicitDeps = getExplicitDeps svcCfg;
        in kixCallPackage pkg svcCfg explicitDeps
      ) allServices
    );

    # 4. Apply cross-cutting modules
    moduleOutputs = applyModules { inherit instances clusterConfig; };

    # 5. Merge module outputs back into instances
    finalInstances = mergeModuleOutputs instances moduleOutputs;

  in {
    inherit finalInstances namespaceResources;
    manifests = concatMap (i: map (r: r.manifest) i.closure) (attrValues finalInstances);
    deploy = mapAttrs (_: i: {
      manifests = map (r: r.manifest) i.main.closure;
    }) finalInstances;
  };
```

---
                                               
## 8. Open Design Questions

### 8.1 Namespace-qualified argument names

What if a package needs to explicitly request a dep from a specific namespace? Possible syntax:

```nix
# Option A: qualified argument name (ugly but explicit)
{ scope, config, "data/valkey" as sessionStore, valkey }:

# Option B: config-level override only (current design)
# No special syntax — just override in cluster config
services.api.sessionStore = instances."data/valkey";

# Option C: package declares with default resolution hint
{ scope, config, valkey }:
let sessionStore = config.sessionStore or valkey; in ...
# Cluster config: services.api.sessionStore = instances."data/valkey";
```

Option B is simplest. Option C is most Nix-idiomatic.

### 8.2 Interface matching

Current design matches on package type name. A richer system would match on *interfaces* — "I need something with a `.fqdn` and `.out.port`" rather than "I need a postgres." This would let cockroachdb satisfy a `postgres` dependency if it exposes the same interface. Worth exploring but adds complexity. Probably a v2 concern.

### 8.3 Resolution stability

Adding a second postgres to the cluster could change resolution for existing services (previously unique → now ambiguous). The evaluator should detect this and list affected services:

```
warning: adding postgres.analytics changes resolution for:
  api (ns: backend) — "postgres" was unambiguous, now has 2 candidates
  → add explicit override: namespaces.backend.services.api.postgres = instances."data/postgres";
```

This is critical for safety. The changeset visualizer should surface this prominently.

### 8.4 Circular namespace reachability

Namespace A allows ingress from B, B allows from A. Both namespaces have services that depend on each other. This is fine — the reachability check is per-direction, not global. But worth noting it doesn't prevent circular service dependencies (which are a real problem in K8s).

---

## 9. Why This Matters (Or Doesn't)

### The case for

**No K8s tool does build-time dependency resolution with reachability checking.** The current state of the art is:
1. Write YAML/HelmFile with string-based service names
2. Deploy
3. Wait for timeout
4. Discover the NetworkPolicy blocks it
5. Fix and redeploy

kixpkgs with auto-resolution catches this at `nix eval` time. The error message tells you exactly which policy blocks the connection and how to fix it.

The DNS-mirroring property means the build-time wiring *predicts* runtime behavior. If eval says `api` resolves to `valkey.backend`, the manifest contains `valkey.backend.svc.cluster.local`, and K8s DNS agrees. The two systems can't diverge.

Combined with the changeset visualizer, the workflow becomes:
1. Declare what services exist and what they need
2. `nix eval` — system resolves deps, checks reachability, catches errors
3. Review changeset — see exactly what resolved to what
4. Deploy with confidence

### The case against

**Implicitness in infrastructure is scary.** When someone asks "what database is prod-app talking to?", the answer should be obvious from the config, not require understanding a resolution algorithm. The counter: the changeset visualizer makes it explicit, and `autoResolve = false` exists for sensitive services.

**K8s already has service discovery.** DNS, service meshes, etc. This is solving a build-time problem that some argue should be a runtime concern. The counter: runtime discovery doesn't give you a dependency DAG, deploy ordering, or pre-deploy validation.

**The resolution algorithm adds cognitive load.** "Same namespace first, then cluster-wide" is simple, but edge cases (multiple candidates, reachability filtering) make it less obvious. The counter: the algorithm mirrors DNS, which every infrastructure engineer already understands.

**Scale question.** For small clusters (5-10 services), manual wiring is fine and maximally explicit. Auto-resolution shines at 30+ services where the wiring becomes the dominant source of boilerplate and bugs.
