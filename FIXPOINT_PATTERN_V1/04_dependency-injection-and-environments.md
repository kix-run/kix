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

Resolution matches on **package type** and **aliases**, not instance name. A service declared as:

```nix
services.analytics-db = { package = "postgres"; namespace = "data"; };
```

...satisfies a `postgres` argument. The package type is `cfg.package or cfg.name` — defaulting to the attribute name when no explicit `package` is set.

Instances can also declare **aliases** — additional names they're discoverable under:

```nix
namespaces.data.services.valkey = {
  package = "valkey";
  aliases = [ "sessionStore" "kvStore" ];
  # Now resolvable as "valkey", "sessionStore", or "kvStore"
};
```

This lets packages request dependencies by *role* rather than by implementation. A package argument `sessionStore` resolves to whatever instance advertises that alias — which could be a valkey, a redis, or anything else that declares `aliases = [ "sessionStore" ]`.

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

Real clusters have repeating structure: dev and prod run the same services with different configs. The DSL should make this structure obvious and concise, not force you to repeat yourself.

### 4.2 Structure

Following the established pattern from `02_kixpkgs-design-doc.md`:

- `namespaces.*` — namespace config only (policies, quotas). No services inside.
- `services.*` — flat, each with a `namespace` field. The instance name is the attribute key.

```nix
{
  namespaces.frontend = {};
  namespaces.backend = {};
  namespaces.data = {
    resourceQuota.hard."requests.storage" = "500Gi";
  };

  services.web-app = {
    namespace = "frontend";
    image = "webapp:v2.1.0";
    replicas = 3;
  };

  services.api = {
    namespace = "backend";
    image = "api:v1.5.0";
    replicas = 3;
  };

  services.backend-cache = {
    package = "valkey";
    namespace = "backend";
    # namespace-local cache, only reachable from backend
  };

  services.postgres = {
    namespace = "data";
    storage = "100Gi";
  };

  services.session-valkey = {
    package = "valkey";
    namespace = "data";
    aliases = [ "sessionStore" ];
    sentinel.enabled = true;
  };
}
```

Two valkey instances with different instance names (`backend-cache`, `session-valkey`) but same package type. DNS-like resolution means:

- `api` (in `backend`) requesting `valkey` → finds `backend-cache` (same namespace, package type matches)
- `api` requesting `sessionStore` → finds `session-valkey` (via alias, cluster-wide)
- `web-app` (in `frontend`) requesting `valkey` → ambiguous (two valkey-type instances, neither in same namespace), must specify explicitly or rely on reachability filtering

If a namespace is referenced by a service but has no `namespaces.*` entry, a bare namespace (no policies) is created automatically.

### 4.3 Environment Variants

An environment is a function from a base service set to a modified one. Like overlays but with a focused purpose: expressing dev/prod differences.

```nix
# clusters/base.nix — shared structure
{
  namespaces.frontend = {};
  namespaces.backend = {};
  namespaces.data = {
    resourceQuota.hard."requests.storage" = "500Gi";
  };

  services.web-app = {
    namespace = "frontend";
    image = "webapp:v2.1.0";
  };

  services.api = {
    namespace = "backend";
    image = "api:v1.5.0";
  };

  services.backend-cache = {
    package = "valkey";
    namespace = "backend";
    persistence.enabled = false;
  };

  services.postgres = {
    namespace = "data";
    storage = "100Gi";
    version = "16";
  };

  services.session-valkey = {
    package = "valkey";
    namespace = "data";
    aliases = [ "sessionStore" ];
    sentinel.enabled = true;
  };
}
```

```nix
# clusters/production.nix
{ base }:
base.withEnvironment {
  name = "prod";

  cluster.labels."env" = "production";

  namespaces.frontend.networkPolicies = [{ /* lock down ingress */ }];
  namespaces.backend.networkPolicies = [{ /* allow from frontend + monitoring */ }];
  namespaces.data = {
    resourceQuota.hard."requests.storage" = "1Ti";
    networkPolicies = [{ /* allow from backend only */ }];
  };

  services.web-app.replicas = 5;
  services.api.replicas = 5;
  services.postgres.storage = "500Gi";
}
```

```nix
# clusters/dev.nix
{ base }:
base.withEnvironment {
  name = "dev";

  cluster.labels."env" = "dev";

  # Global default: 1 replica for everything
  defaults.replicas = 1;

  services.postgres.storage = "10Gi";

  # No network policies in dev — everything can talk to everything
  # No resource quotas — dev clusters are small anyway
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

The key property: `base.nix` is the single source of truth for *what services exist*. Environment files only say *how this environment differs*. Add a new service to base → it appears in all environments.

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
# Depends on postgres (DB), valkey (cache), and sessionStore (sessions).
# Resolution:
#   valkey       → finds valkey.backend (same namespace, local cache)
#   postgres     → finds postgres.data (only postgres in cluster)
#   sessionStore → defaults to valkey if not resolved separately.
#                  The cluster can alias a different instance as "sessionStore"
#                  to override this.
{ scope, config, postgres, valkey, sessionStore ? valkey }:

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
            # valkey.backend — same namespace, local cache
            value = scope.str [
              "redis://" valkey.fqdn ":" valkey.out.port
            ];
          }
          {
            name = "SESSION_URL";
            # sessionStore defaults to valkey (same instance as cache)
            # but when data/valkey has aliases = ["sessionStore"],
            # resolution finds that instead → separate session backend
            value = scope.str [
              "redis://" sessionStore.fqdn ":" sessionStore.out.port
            ];
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
  namespaces.frontend = {};
  namespaces.backend = {};
  namespaces.data = {};

  services.web-app = {
    namespace = "frontend";
    image = "webapp:v2.1.0";
    # "api" dep resolved automatically:
    #   1. api in frontend? No.
    #   2. api cluster-wide unique? Yes (package type "api") → api
  };

  services.api = {
    namespace = "backend";
    image = "api:v1.5.0";
    # "postgres" dep → postgres (only one in cluster, unique)
    # "valkey" dep → backend-cache (same namespace, package type "valkey")
    # "sessionStore" dep → session-valkey (via alias, cluster-wide)
  };

  services.backend-cache = {
    # This IS the namespace-local cache.
    # No sentinel, no persistence — ephemeral response cache.
    package = "valkey";
    namespace = "backend";
    persistence.enabled = false;
    maxmemory = "256Mi";
    eviction = "allkeys-lru";
  };

  services.postgres = {
    namespace = "data";
    storage = "100Gi";
    version = "16";
  };

  services.session-valkey = {
    # Shared session/queue store.
    # Sentinel for HA, persistence on.
    package = "valkey";
    namespace = "data";
    aliases = [ "sessionStore" ];   # discoverable as "sessionStore" by other packages
    sentinel.enabled = true;
    persistence.enabled = true;
  };
}
```

### 5.3 Resolution Trace

What the evaluator does with `api` in namespace `backend`:

```
api needs "postgres":
  1. postgres (type) in backend?  → no
  2. postgres cluster-wide        → services.postgres (unique) ✓
  Resolved: services.postgres (ns: data)

api needs "valkey":
  1. valkey (type) in backend?    → yes: services.backend-cache ✓
  Resolved: services.backend-cache (ns: backend)
  (session-valkey is also type "valkey" but same-namespace wins)

api needs "sessionStore":
  Arg has default (? valkey), so resolution is optional.
  1. sessionStore (type+alias) in backend?  → no
  2. sessionStore cluster-wide              → session-valkey has aliases = ["sessionStore"] ✓
  Resolved: services.session-valkey (ns: data, via alias)
  (Default `? valkey` is NOT used — an alias match was found)

  If session-valkey had NO alias:
  → no "sessionStore" found → fall back to Nix default → uses resolved `valkey` arg
  → api.CACHE_URL and api.SESSION_URL both point to backend-cache

web-app needs "api":
  1. api (type) in frontend?  → no
  2. api cluster-wide          → services.api (unique) ✓
  Resolved: services.api (ns: backend)
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
      podSelector = {};
      policyTypes = [ "Ingress" ];
      ingress = [{
        from = [{ namespaceSelector.matchLabels."app" = "ingress"; }];
      }];
    }];
  };

  namespaces.backend.networkPolicies = [{
    podSelector = {};
    policyTypes = [ "Ingress" ];
    ingress = [{
      from = [
        { namespaceSelector.matchLabels."env/ns" = "frontend"; }
        { namespaceSelector.matchLabels."app" = "monitoring"; }
      ];
    }];
  }];

  namespaces.data = {
    resourceQuota.hard."requests.storage" = "1Ti";
    networkPolicies = [{
      podSelector = {};
      policyTypes = [ "Ingress" ];
      ingress = [{
        from = [{ namespaceSelector.matchLabels."env/ns" = "backend"; }];
      }];
    }];
  };

  services.web-app.replicas = 5;
  services.api.replicas = 5;
  services.postgres.storage = "500Gi";

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

  services.postgres.storage = "10Gi";

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
          └─ dep → Service/api (ns: backend)              ← cross-namespace via fqdn
                    ├─ dep → Namespace/backend
                    │         └─ req → NetworkPolicy/backend-netpol-0
                    │
                    └─ req → Deployment/api (ns: backend)
                              ├─ dep → Service/postgres (ns: data)      ← "postgres" arg
                              │         ├─ dep → Namespace/data
                              │         │         ├─ req → ResourceQuota/data-quota
                              │         │         └─ req → NetworkPolicy/data-netpol-0
                              │         └─ req → StatefulSet/postgres
                              │
                              ├─ dep → Service/backend-cache (ns: backend) ← "valkey" arg (same-ns)
                              │         └─ req → Deployment/backend-cache
                              │
                              └─ dep → Service/session-valkey (ns: data)   ← "sessionStore" arg (alias)
                                        └─ req → StatefulSet/session-valkey
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
services.web-app        = { namespace = "frontend"; image = "webapp:v2.1.0"; };
services.api            = { namespace = "backend";  image = "api:v1.5.0"; };
services.backend-cache  = { namespace = "backend";  package = "valkey"; };
services.postgres       = { namespace = "data";     storage = "100Gi"; };
services.session-valkey = { namespace = "data";     package = "valkey"; aliases = ["sessionStore"]; };
```

5 lines. All wiring is automatic — api gets a local cache valkey (same namespace) AND a separate session store from data (via alias). Add `services.api.replicas = 5` in the prod environment and you're done.

**Helm equivalent** for the same setup: 5 charts, 5 values files (minimum), manual namespace creation, no cross-chart dependency tracking, no deploy ordering, no reachability checking, and a bash script to apply them in the right order.

---

## 6. Implementation Sketch: `kixCallPackage`

```nix
kixCallPackage = packageFn: instanceConfig: explicitDeps:
  let
    fnArgs = builtins.functionArgs packageFn;
    depArgNames = attrNames (removeAttrs fnArgs [ "scope" "config" "lib" ]);

    # Which args have Nix-level defaults (e.g., sessionStore ? valkey)
    hasDefault = filterAttrs (_: hasDefault: hasDefault) fnArgs;

    myNs = instanceConfig.namespace;

    # Index instances by package type AND all their aliases
    # An instance with package="valkey" aliases=["sessionStore"]
    # appears under both "valkey" and "sessionStore"
    byKey = let
      pairs = concatMap (inst:
        let
          type = inst.package or inst.name;
          keys = [ type ] ++ (inst.aliases or []);
        in map (k: { name = k; value = inst; }) keys
      ) allInstances;
    in groupBy (p: p.name) pairs |> mapAttrs (_: map (p: p.value));

    resolve = argName:
      let
        candidates = byKey.${argName} or [];
        sameNs = filter (c: c.namespace == myNs) candidates;
        reachable = filter (c: isReachable myNs c.namespace) candidates;
        sameNsReachable = filter (c: c.namespace == myNs) reachable;
      in
        if length sameNsReachable == 1 then { found = true; value = head sameNsReachable; }
        else if length sameNs > 1 then
          throw "${instanceConfig.name}: multiple '${argName}' in namespace ${myNs} — specify explicitly"
        else if length reachable == 1 then { found = true; value = head reachable; }
        else if candidates != [] && reachable == [] then
          throw "${instanceConfig.name}: '${argName}' exists but unreachable (NetworkPolicy)"
        else if length reachable > 1 then
          throw "${instanceConfig.name}: multiple reachable '${argName}' — specify explicitly"
        # No match: if the arg has a Nix default, let it fall through.
        # If it doesn't, that's an error.
        else if hasDefault ? ${argName} then { found = false; }
        else throw "${instanceConfig.name}: no '${argName}' in cluster";

    autoResolved =
      if !(instanceConfig.autoResolve or clusterConfig.autoResolve or true)
      then {}  # all deps must come from explicitDeps
      else let
        results = genAttrs depArgNames resolve;
        # Only inject args where resolution found something.
        # Args with found=false have Nix defaults — don't inject, let Nix use the default.
        resolved = filterAttrs (_: r: r.found) results;
      in mapAttrs (_: r: r.value) resolved;

    # Check for unresolved args that have no default
    requiredArgs = filter (name: !(hasDefault ? ${name})) depArgNames;
    unresolved = subtractLists (attrNames (autoResolved // explicitDeps)) requiredArgs;
    _ = assert unresolved == [] ||
      throw "${instanceConfig.name}: unresolved deps: ${toString unresolved}";

  in packageFn ({
    scope = mkScope instanceConfig;
    config = instanceConfig;
  } // autoResolved // explicitDeps);  # explicit always wins
```

---

## 7. The `buildCluster` Evaluator

```nix
buildCluster = clusterConfig:
  let
    # 1. Build namespace resources with policies
    #    Any namespace referenced by a service but not declared gets a bare entry.
    allNamespaces = collectNamespaces clusterConfig;  # from namespaces.* + services.*.namespace
    namespaceResources = mapAttrs (name: nsCfg:
      k8s.mkNamespace {
        inherit name;
        inherit (nsCfg) resourceQuota limitRange networkPolicies;
        labels = clusterConfig.cluster.labels // { "env/ns" = name; };
      }
    ) allNamespaces;

    # 2. Outer fixpoint: all instances see each other
    instances = lib.fix (self:
      mapAttrs (instanceName: svcCfg:
        let
          pkg = loadPackage (svcCfg.package or instanceName);
          scope = mkScope svcCfg namespaceResources.${svcCfg.namespace};
          explicitDeps = getExplicitDeps svcCfg;
        in kixCallPackage pkg svcCfg explicitDeps
      ) clusterConfig.services
    );

    # 3. Apply cross-cutting modules
    moduleOutputs = applyModules { inherit instances clusterConfig; };

    # 4. Merge module outputs back into instances
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

### 8.1 Multiple same-type dependencies and role aliases

**Decided:** Packages use Nix default arguments to express role deps with fallbacks.
Instances use `aliases` to advertise roles they can fill.

```nix
# Package side: default arguments with fallback to a resolved dep
{ scope, config, postgres, valkey, sessionStore ? valkey }:
# sessionStore falls back to whatever valkey resolved to,
# unless an instance with alias "sessionStore" is found.
```

```nix
# Cluster side: aliases make an instance discoverable under additional names
namespaces.data.services.valkey = {
  package = "valkey";
  aliases = [ "sessionStore" ];   # resolvable as "valkey" OR "sessionStore"
};
```

Resolution order for a defaulted argument like `sessionStore ? valkey`:

1. Try normal resolution (package type + aliases, namespace-first)
2. If a match is found → use it (alias or type match wins over default)
3. If no match → use the default value (the already-resolved `valkey`)

This keeps packages pure Nix (no custom syntax), lets the cluster operator control
which instance fills which role, and degrades gracefully — if nobody declares a
`sessionStore` alias, the package just uses its local valkey for everything.

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
