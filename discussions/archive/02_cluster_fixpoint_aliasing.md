# The Cluster-Level Fixpoint: Instance Aliasing and Dependency Injection

## Working Document — March 2026

**Status:** v2 design exploration
**Context:** Builds on FIXPOINT_PATTERN_V1 docs 02, 04, 05, and 06

---

## 1. What This Document Decides

The v1 design docs (especially 04 and 06) established the *concepts* — DNS-like resolution, aliases, auto-install, scope blocks. This document pins down the *mechanics*: what exactly is in the outer fixpoint, how aliases become attrset entries, how `callPackage`-style injection works, and what happens at the edges (conflicts, cross-namespace, default arguments).

The goal is a concrete, implementable specification with code you could drop into a prototype.

---

## 2. The Outer Fixpoint: Structure

### 2.1 What Lives in the Fixpoint

The outer fixpoint is a flat attrset of **instantiated packages** keyed by instance name:

```nix
clusterInstances = lib.fix (self: {
  web-app       = <instantiated package>;
  api           = <instantiated package>;
  backend-cache = <instantiated package>;
  postgres      = <instantiated package>;
  session-valkey = <instantiated package>;
})
```

Each value is the result of evaluating the inner fixpoint for that package — meaning it's an attrset with `main`, `closure`, resource references, `fqdn`, `out`, etc.

The fixpoint is flat, not namespaced. Instance names are unique across the cluster. This is a deliberate choice: it mirrors the fact that Kubernetes service DNS names are only unique *within* a namespace, but instance identity in kixpkgs needs to be cluster-global for the fixpoint to work.

### 2.2 Metadata Alongside Instances

Each entry in the fixpoint carries metadata that the resolution system uses. This metadata comes from the cluster config (the DSL layer), not from the package itself:

```nix
clusterInstances = lib.fix (self:
  mapAttrs (instanceName: svcCfg:
    let
      pkg = loadPackage (svcCfg.package or instanceName);
      scope = mkScope instanceName svcCfg.namespace;
      resolved = resolveAndInject pkg svcCfg self;
    in resolved // {
      # Resolution metadata — attached to the instantiated package
      _meta = {
        instanceName = instanceName;
        packageType = svcCfg.package or instanceName;
        namespace = svcCfg.namespace;
        aliases = svcCfg.aliases or [];
      };
    }
  ) clusterConfig.services
);
```

The `_meta` attrset is what the resolution algorithm indexes over. It is NOT part of the package's inner fixpoint — it's cluster-level metadata.

### 2.3 Why Not Nested by Namespace?

An alternative would be `{ namespace -> { instanceName -> package } }`. This was rejected because:

1. Cross-namespace references would require `self.data.postgres` instead of `self.postgres`, leaking namespace structure into the fixpoint.
2. Overlays would need to target `self.data.postgres` — more verbose and fragile if a service moves namespaces.
3. The fixpoint exists for dependency resolution. Dependencies are between instances, not between namespaces.

Namespaces ARE in the fixpoint — as instances themselves (their `main` is the Namespace resource, with `requires` for policies). But they're peers to services, not containers.

---

## 3. The Resolution Index

### 3.1 Building the Index

Before resolving any individual package's dependencies, the system builds a lookup index from all instances in the fixpoint. This index is what makes alias resolution fast and unambiguous.

```nix
# Built once per fixpoint evaluation, used by all resolution calls
buildResolutionIndex = allInstances:
  let
    instances = attrValues allInstances;

    # Each instance is indexed under its package type AND all aliases
    indexEntries = concatMap (inst:
      let
        meta = inst._meta;
        keys = [ meta.packageType ] ++ meta.aliases;
      in map (key: { inherit key; instance = inst; }) keys
    ) instances;

    # Group by key -> list of instances
    byKey = groupBy (e: e.key) indexEntries
            |> mapAttrs (_: map (e: e.instance));

  in { inherit byKey; };
```

This index is conceptually a multimap: `{ "postgres" -> [ postgres-instance ]; "valkey" -> [ backend-cache, session-valkey ]; "sessionStore" -> [ session-valkey ]; }`.

### 3.2 Alias Entries Are NOT Fixpoint Entries

A critical design decision: aliases do NOT create additional entries in the fixpoint attrset. The fixpoint contains exactly one entry per instance, keyed by instance name. Aliases exist only in the resolution index.

Why this matters:

```nix
# This is what the fixpoint looks like:
self = {
  session-valkey = <package>;    # has _meta.aliases = [ "sessionStore" ]
  # There is NO self.sessionStore entry
};

# Aliases are resolved via the index, not via attrset lookup
```

If aliases were fixpoint entries, you'd have two paths to the same instance (`self.session-valkey` and `self.sessionStore`), which creates confusion about identity, complicates overlays (which one do you override?), and makes the fixpoint's structure dependent on configuration rather than declaration.

The fixpoint is the source of truth for what exists. The resolution index is a derived view for dependency injection.

### 3.3 Conflict Detection

Aliases can collide. Two instances could both declare `aliases = [ "sessionStore" ]`. The resolution index naturally handles this — the key maps to a list, and the resolution algorithm (section 4) disambiguates or errors.

But there's a harder case: an alias colliding with a package type name. If instance `foo` has `package = "bar"` and instance `baz` has `aliases = [ "bar" ]`, then the key `"bar"` maps to both. This is allowed — the resolution algorithm treats them identically (both are candidates for an argument named `bar`).

The evaluator should warn (not error) when an alias shadows a package type, since it's a likely source of confusion:

```
warning: alias "bar" on instance "baz" shadows package type "bar" (instance "foo").
  Both will be candidates when resolving argument "bar".
  Consider using a more specific alias name.
```

---

## 4. Dependency Injection: The `kixCallPackage` Mechanism

### 4.1 How It Works

Dependency injection follows `callPackage` semantics: introspect the package function's arguments, resolve each one, call the function.

```nix
kixCallPackage =
  { packageFn          # The package's outer function: { scope, config, postgres, ... }: self: { ... }
  , instanceConfig     # The cluster-level config for this instance
  , allInstances       # The full outer fixpoint (self)
  , resolutionIndex    # Pre-built resolution index
  }:
  let
    fnArgs = builtins.functionArgs packageFn;

    # System-provided args (never resolved)
    systemArgs = [ "scope" "config" "lib" ];

    # Dependency args: everything else
    depArgNames = attrNames (removeAttrs fnArgs (listToAttrs (map (n: { name = n; value = true; }) systemArgs)));

    # Which args have Nix-level defaults (? syntax)
    argHasDefault = filterAttrs (_: hasDefault: hasDefault) fnArgs;

    # Resolve each dependency argument
    resolvedDeps = foldl' (acc: argName:
      let resolution = resolveArg {
        inherit argName resolutionIndex;
        requesterNamespace = instanceConfig.namespace;
        requesterName = instanceConfig._name or "unknown";
        hasDefault = argHasDefault ? ${argName} or false;
        explicitOverride = instanceConfig.${argName} or null;
      };
      in if resolution.found
         then acc // { ${argName} = resolution.value; }
         else acc  # arg has a Nix default, let it fall through
    ) {} depArgNames;

    scope = mkScope instanceConfig;

  in packageFn ({
    inherit scope;
    config = instanceConfig;
  } // resolvedDeps);
```

### 4.2 Resolution Algorithm

This is the core algorithm. It runs for each dependency argument of each package.

```nix
resolveArg =
  { argName
  , resolutionIndex
  , requesterNamespace
  , requesterName
  , hasDefault          # Does the Nix function have ? default for this arg
  , explicitOverride    # Did the cluster config wire this explicitly
  }:

  # 1. Explicit override always wins
  if explicitOverride != null then
    { found = true; value = explicitOverride; }

  # 2. DNS-like resolution
  else let
    candidates = resolutionIndex.byKey.${argName} or [];

    # Partition by namespace proximity
    sameNs = filter (c: c._meta.namespace == requesterNamespace) candidates;
    otherNs = filter (c: c._meta.namespace != requesterNamespace) candidates;

    # Reachability filtering (when NetworkPolicies exist)
    reachableSameNs = sameNs;  # same-ns is always reachable
    reachableOtherNs = filter (c: isReachable requesterNamespace c._meta.namespace) otherNs;
    allReachable = reachableSameNs ++ reachableOtherNs;

  in
    # 2a. Exactly one in same namespace -> use it
    if length reachableSameNs == 1 then
      { found = true; value = head reachableSameNs; }

    # 2b. Multiple in same namespace -> ambiguous error
    else if length reachableSameNs > 1 then
      throw "${requesterName}: multiple '${argName}' in namespace ${requesterNamespace}: ${showCandidates reachableSameNs}. Specify explicitly."

    # 2c. None in same namespace, exactly one reachable cluster-wide -> use it
    else if reachableSameNs == [] && length reachableOtherNs == 1 then
      { found = true; value = head reachableOtherNs; }

    # 2d. Candidates exist but none reachable -> error with NetworkPolicy guidance
    else if candidates != [] && allReachable == [] then
      throw "${requesterName}: '${argName}' found but all unreachable (blocked by NetworkPolicy). Candidates: ${showCandidates candidates}"

    # 2e. Multiple reachable cluster-wide -> ambiguous error
    else if length reachableOtherNs > 1 then
      throw "${requesterName}: multiple reachable '${argName}' cluster-wide: ${showCandidates reachableOtherNs}. Specify explicitly."

    # 2f. No candidates at all
    else if hasDefault then
      { found = false; }  # Let Nix's ? default handle it

    else
      throw "${requesterName}: no '${argName}' found in cluster. Declare a service with package type or alias '${argName}', or provide an explicit override.";
```

### 4.3 The Priority Chain

Summarized:

```
1. Explicit override in cluster config             (user wired it)
2. Same-namespace match (package type or alias)     (DNS-local behavior)
3. Cluster-wide unique reachable match              (DNS-search behavior)
4. Nix function default (? syntax)                  (package-level fallback)
5. Eval error                                       (missing dependency)
```

This mirrors Kubernetes DNS resolution: `redis` resolves to `redis.<my-namespace>.svc.cluster.local` first, then falls back to search domains. The build-time behavior predicts runtime behavior.

---

## 5. The `? redis` Pattern: Default Arguments as Interface Hints

### 5.1 What It Means

```nix
# kixpkgs/my-app.nix
{ scope, config, postgres, valkey, sessionStore ? valkey }:
```

This declares: "I need a `sessionStore`. If the cluster doesn't provide one, use whatever `valkey` resolved to."

The `?` default is a **Nix language feature**, not a kixpkgs feature. But it interacts with resolution in a specific way that needs to be precisely defined.

### 5.2 Resolution Interaction

When the resolver encounters an argument with a Nix default:

1. It still tries to resolve `sessionStore` via the resolution index.
2. If a match is found (package type or alias), that match wins over the default.
3. If NO match is found, the resolver returns `{ found = false; }` — it does NOT inject anything.
4. Nix's own default mechanism kicks in: `sessionStore` evaluates to the value of `valkey` (which was already resolved).

This is subtle and important. The resolver deliberately leaves a gap that Nix fills. It does not try to evaluate the default expression itself — that would require parsing Nix AST. Instead, by not injecting the argument, Nix naturally uses the default.

### 5.3 The Default Value Is an Expression, Not a Type

In `sessionStore ? valkey`, the default `valkey` refers to the already-resolved `valkey` argument — not to "any valkey-type package." This is because Nix evaluates the function arguments left-to-right in a shared scope.

This means the default is a **concrete instance**, not a type query. The package is saying: "give me a session store; if you don't have a dedicated one, I'll reuse my valkey." It is NOT saying: "give me anything that looks like a valkey."

### 5.4 Interface/Protocol Matching (Future Direction)

The current system matches on string names: package type names and alias strings. There is no structural matching ("give me anything with `.fqdn` and `.out.port`").

A richer system could support interfaces:

```nix
# Hypothetical: package declares it implements an interface
# kixpkgs/valkey.nix
{
  implements = [ "kv-store" "session-store" ];
  # ...
}

# Consumer asks for an interface
{ scope, config, sessionStore ? kv-store }:
# Resolves to any instance implementing "session-store"
```

This is worth exploring in v2 but not in scope for this document. The name-based system covers 90%+ of real cases, and interface matching adds significant complexity (interface registries, compatibility checking, version constraints).

For now, **aliases are the mechanism for role-based resolution**. If you want a valkey instance to satisfy `sessionStore`, you add `aliases = [ "sessionStore" ]`. This is explicit, auditable, and requires no type system.

---

## 6. Cross-Namespace Dependencies

### 6.1 How They Work in the Fixpoint

The fixpoint is flat — cross-namespace dependencies are no different from same-namespace dependencies at the fixpoint level. The difference is in what the resolved instance exposes:

```nix
# When api (backend) depends on postgres (data):
# The resolution gives api the postgres instance object.
# api uses postgres.fqdn, which resolves to:
#   "postgres.data.svc.cluster.local"
# This is a cross-namespace FQDN with an automatic ref-tracked dependency.
```

The `fqdn` field on an instance is namespace-aware:

```nix
# Inside mkScope / instance construction
fqdn = mkRef self "fqdn" "${instanceName}.${namespace}.svc.cluster.local";
```

Same-namespace references can use short names (just `instanceName`), but the system always generates FQDNs for cross-namespace refs to match DNS behavior.

### 6.2 Namespace as Dependency

When a resource is created in a namespace, it automatically depends on the Namespace resource (via `scope.mkResource` injecting `namespace = ns`). Cross-namespace dependencies therefore transitively pull in the target namespace and all its policies.

```
api (ns: backend)
  -> postgres (ns: data)           # dependency via resolution
       -> Namespace/data           # automatic via scope
            -> NetworkPolicy/...   # via requires on the Namespace
            -> ResourceQuota/...
```

This means deploying `api` automatically ensures the `data` namespace exists with its policies. No manual ordering needed.

### 6.3 Reachability Is a Soft Check

Reachability (NetworkPolicy analysis) runs during resolution but is advisory, not structural. The fixpoint does not encode reachability — it encodes dependency. A cross-namespace dependency is valid even if a NetworkPolicy blocks it; the evaluator warns (or errors, depending on config) so the user can fix the policy or override the resolution.

---

## 7. Alias Resolution: When and How

### 7.1 Timing

Aliases are resolved at **fixpoint evaluation time**, as part of `kixCallPackage`. They are not a pre-processing step. The sequence is:

```
1. DSL layer produces { instanceName -> serviceConfig }
2. mkCluster builds namespace resources
3. Outer fixpoint evaluates:
   a. For each instance, build the resolution index from all instances' _meta
   b. For each instance, call kixCallPackage with the index
   c. kixCallPackage resolves each dep argument using the index
   d. Package function is called with resolved deps
   e. Inner fixpoint evaluates (resources reference each other)
4. Cross-cutting modules run
5. Module outputs merged back
```

Step 3a-3c is where aliases matter. The resolution index is built from `_meta.aliases`, which comes from the cluster config (`svcCfg.aliases`), not from the package definition.

### 7.2 Aliases Are Cluster-Level, Not Package-Level

A package does NOT declare its aliases. The cluster operator assigns aliases:

```nix
# Correct: alias is in the cluster config
services.session-valkey = {
  package = "valkey";
  aliases = [ "sessionStore" ];
};

# The valkey package itself has no idea it's aliased as sessionStore.
# It doesn't need to — it just receives scope, config, and deps like any package.
```

This separation is intentional. The same valkey package can be deployed as `backend-cache` (no aliases, namespace-local) and as `session-valkey` (aliased as `sessionStore`, cluster-wide). The package doesn't change. The alias is a deployment decision.

### 7.3 Alias Uniqueness

Aliases do not need to be globally unique — the resolution algorithm handles ambiguity. But in practice, a role alias like `sessionStore` SHOULD be unique cluster-wide, because the whole point is to provide a single answer to "who is the session store?"

The evaluator should warn when multiple instances share an alias, since it means resolution will always require namespace proximity or explicit override to disambiguate:

```
warning: alias "sessionStore" is declared by multiple instances:
  session-valkey (ns: data)
  session-redis  (ns: backend)
  Resolution will use namespace proximity. Consider using unique aliases
  or explicit overrides.
```

---

## 8. Concrete Code Example: Full Cluster with Aliases

### 8.1 Package Definitions

```nix
# kixpkgs/valkey.nix — a generic valkey/redis package
{ scope, config }:

self: {
  statefulset = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    name = scope.instanceName;
    spec = {
      replicas = config.replicas or 1;
      template.spec.containers = [{
        name = "valkey";
        image = "valkey/valkey:${config.version or "7.2"}";
        ports = [{ containerPort = 6379; }];
      }];
    };
  };

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = scope.instanceName;
    spec.ports = [{ port = 6379; targetPort = 6379; }];
    outputs = { port = 6379; };
  };

  main = self.service // { requires = [ self.statefulset ]; };
}
```

```nix
# kixpkgs/api-server.nix — an application that needs a DB and session store
{ scope, config, postgres, valkey, sessionStore ? valkey }:

self: {
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
            value = scope.str [ "postgresql://" postgres.fqdn ":" postgres.out.port "/mydb" ];
          }
          {
            name = "CACHE_URL";
            value = scope.str [ "redis://" valkey.fqdn ":" valkey.out.port ];
          }
          {
            name = "SESSION_URL";
            value = scope.str [ "redis://" sessionStore.fqdn ":" sessionStore.out.port ];
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

  main = self.service // { requires = [ self.deployment ]; };
}
```

### 8.2 Cluster Definition (DSL Layer)

```nix
# Using approach E ("just functions") from doc 06
let
  k = import ./kixpkgs;
  ns = k.inNamespace;
in k.mkCluster {

  services =
    ns "frontend" {
      web-app = { image = "webapp:v2.1.0"; replicas = 3; };
    }
    // ns "backend" {
      api = { package = "api-server"; image = "api:v1.5.0"; replicas = 3; };
      cache = { package = "valkey"; };
    }
    // ns "data" {
      postgres = { storage = "100Gi"; version = "16"; };
      session-valkey = {
        package = "valkey";
        aliases = [ "sessionStore" "kvStore" ];
        sentinel.enabled = true;
      };
    };

  namespaces.data.resourceQuota.hard."requests.storage" = "500Gi";
}
```

### 8.3 What the Outer Fixpoint Looks Like

After `mkCluster` processes the DSL input, the outer fixpoint evaluates to:

```nix
# Conceptual result of lib.fix (self: ...)
{
  web-app = {
    # Inner fixpoint result for web-app package
    main = <Service/web-app>;
    deployment = <Deployment/web-app>;
    service = <Service/web-app>;
    closure = [ <Namespace/frontend> <Service/web-app> <Deployment/web-app> <Service/api (cross-ns dep)> ... ];
    fqdn = "web-app.frontend.svc.cluster.local";
    _meta = { instanceName = "web-app"; packageType = "web-app"; namespace = "frontend"; aliases = []; };
  };

  api = {
    main = <Service/api>;
    # ...
    # postgres -> resolved to self.postgres (unique cluster-wide)
    # valkey   -> resolved to self.cache (same namespace, package type "valkey")
    # sessionStore -> resolved to self.session-valkey (alias match)
    _meta = { instanceName = "api"; packageType = "api-server"; namespace = "backend"; aliases = []; };
  };

  cache = {
    main = <Service/cache>;
    # ...
    _meta = { instanceName = "cache"; packageType = "valkey"; namespace = "backend"; aliases = []; };
  };

  postgres = {
    main = <Service/postgres>;
    # ...
    _meta = { instanceName = "postgres"; packageType = "postgres"; namespace = "data"; aliases = []; };
  };

  session-valkey = {
    main = <Service/session-valkey>;
    # ...
    _meta = { instanceName = "session-valkey"; packageType = "valkey"; namespace = "data"; aliases = [ "sessionStore" "kvStore" ]; };
  };
}
```

### 8.4 Resolution Trace for `api`

```
Resolving deps for "api" (ns: backend, package: api-server):

  Arg "postgres":
    1. Explicit override? No.
    2. Index lookup "postgres" -> [ postgres(data) ]
    3. Same namespace? No (postgres is in data, api is in backend).
    4. Cluster-wide unique reachable? Yes -> postgres(data).
    Result: self.postgres

  Arg "valkey":
    1. Explicit override? No.
    2. Index lookup "valkey" -> [ cache(backend), session-valkey(data) ]
    3. Same namespace? Yes: cache(backend).
    4. Exactly one same-ns match -> cache(backend).
    Result: self.cache

  Arg "sessionStore" (has Nix default: ? valkey):
    1. Explicit override? No.
    2. Index lookup "sessionStore" -> [ session-valkey(data) ]
       (session-valkey has aliases = ["sessionStore"])
    3. Same namespace? No.
    4. Cluster-wide unique reachable? Yes -> session-valkey(data).
    Result: self.session-valkey
    (Nix default ? valkey is NOT used — alias match found.)

  Final call:
    api-server-package {
      scope = <scope for api in backend>;
      config = { image = "api:v1.5.0"; replicas = 3; ... };
      postgres = self.postgres;
      valkey = self.cache;
      sessionStore = self.session-valkey;
    }
```

### 8.5 What Happens Without the Alias

If `session-valkey` did NOT have `aliases = [ "sessionStore" ]`:

```
  Arg "sessionStore" (has Nix default: ? valkey):
    1. Explicit override? No.
    2. Index lookup "sessionStore" -> []  (no package type or alias matches)
    3. No candidates. Arg has Nix default.
    Result: { found = false; }  — not injected.

  Nix evaluates: sessionStore ? valkey
  Since sessionStore was not injected, the default fires.
  sessionStore = valkey = self.cache (the backend-namespace valkey).

  Effect: CACHE_URL and SESSION_URL both point to cache.backend.
```

This is the graceful degradation property: without a dedicated session store, the app reuses its cache. With one, it gets a separate instance. The package code doesn't change.

---

## 9. Overlays and the Resolution Index

### 9.1 Overlays Operate on the Fixpoint, Not the Index

Overlays modify instances in the outer fixpoint. The resolution index is rebuilt from the modified fixpoint.

```nix
myOverlay = self: super: {
  # Add a dedicated session store
  session-redis = kixCallPackage redisPackage {
    namespace = "backend";
    aliases = [ "sessionStore" ];
  };
};
```

After this overlay, the resolution index gains a `"sessionStore"` entry pointing to `session-redis` in the `backend` namespace. If `api` is also in `backend`, it now resolves `sessionStore` to `session-redis` (same-namespace wins).

### 9.2 Overlay Can Change Aliases

```nix
# Move the sessionStore alias from session-valkey to a new redis instance
myOverlay = self: super: {
  session-valkey = super.session-valkey.overrideConfig (cfg: cfg // {
    aliases = removeList [ "sessionStore" ] cfg.aliases;
  });
  session-redis = instantiate redisPackage {
    namespace = "data";
    aliases = [ "sessionStore" ];
  };
};
```

This is a cluster-level reconfiguration: change which instance fills the `sessionStore` role. All packages that depend on `sessionStore` automatically re-resolve to the new instance through the fixpoint.

### 9.3 The Resolution Index Must Be Lazy

The resolution index is derived from `self` (the fixpoint). If it were eagerly computed, you'd get infinite recursion — computing the index requires knowing all instances, but instances are being computed using the index.

Solution: the index is part of the fixpoint itself, or computed lazily per-resolution-call.

```nix
clusterInstances = lib.fix (self:
  let
    # The index is lazy — each entry is only accessed when needed
    resolutionIndex = buildResolutionIndex self;
  in mapAttrs (instanceName: svcCfg:
    kixCallPackage {
      packageFn = loadPackage svcCfg;
      instanceConfig = svcCfg;
      allInstances = self;
      inherit resolutionIndex;
    }
  ) clusterConfig.services
);
```

This works because Nix is lazy: `buildResolutionIndex self` doesn't force evaluation of all instances. It only accesses `_meta` of each instance — and `_meta` is computed from cluster config (static), not from the inner fixpoint (dynamic). So there's no circular dependency.

If `_meta` were computed from the package's evaluation result, you'd hit infinite recursion. This is why `_meta` comes from the DSL input, not from the package output.

---

## 10. Edge Cases and Design Decisions

### 10.1 Instance Name Colliding with Package Type

If you name an instance `valkey` and it has `package = "valkey"`, that's fine — the instance name doesn't participate in resolution. Only `_meta.packageType` and `_meta.aliases` do.

If you name an instance `sessionStore` and a different instance has `aliases = [ "sessionStore" ]`, the resolution index has two entries under `"sessionStore"`. This is resolved by the normal algorithm (namespace proximity, uniqueness).

### 10.2 Self-Reference in Resolution

Can a package resolve a dependency to itself? Technically yes — if `api` has package type `"api-server"` and some other package requests `api-server`, it would resolve to `api`. But a package requesting its own package type would be unusual and likely a bug. The system doesn't prevent it but also doesn't need to special-case it.

### 10.3 Circular Dependencies Between Packages

The outer fixpoint handles this naturally — Nix's lazy evaluation means `A` can depend on `B` and `B` on `A` as long as neither forces strict evaluation of the other during construction. In practice, packages reference each other's `fqdn` and `out.*`, which are leaf values that don't trigger further fixpoint evaluation.

```nix
# api depends on worker (sends async jobs)
# worker depends on api (calls back with results)
# Both reference each other's fqdn — no circular eval because
# fqdn is a static value derived from instanceName + namespace
```

### 10.4 Resolution Stability Under Mutation

Adding a second instance of the same package type can change resolution for existing consumers (from "unique cluster-wide" to "ambiguous"). The evaluator MUST detect this and produce actionable errors:

```
error: resolution for "api" (ns: backend) changed:
  Arg "valkey" previously resolved to cache (ns: backend) — still resolves there (same-ns priority).
  Arg "postgres" previously resolved to postgres (ns: data) — NOW AMBIGUOUS:
    postgres (ns: data)
    analytics-db (ns: analytics, package: postgres)
  Fix: add explicit override in services.api.postgres = ...;
```

This requires the evaluator to track resolution provenance (which rule matched). See section 11.

### 10.5 Auto-Install Interaction

Auto-install (doc 05, approach D) adds a "virtual pool" of all registry packages to the fixpoint. These pool entries have `_meta` but no aliases (auto-installed instances don't advertise roles — that's a cluster operator decision). Resolution falls through to the pool only when no explicit instance matches.

The pool does NOT participate in alias resolution. If you want an auto-installed valkey to be the session store, you have to promote it to explicit and add the alias. This is deliberate: auto-install is for convenience, aliases are for intentional architecture.

---

## 11. Resolution Provenance

For debuggability, every resolved dependency should record HOW it was resolved:

```nix
# Attached to the instantiated package (alongside _meta)
_resolution = {
  postgres = {
    resolvedTo = "postgres";  # instance name
    rule = "cluster-wide-unique";  # which resolution step matched
    candidates = [ "postgres" ];
    namespace = "data";
  };
  valkey = {
    resolvedTo = "cache";
    rule = "same-namespace";
    candidates = [ "cache" "session-valkey" ];
    namespace = "backend";
  };
  sessionStore = {
    resolvedTo = "session-valkey";
    rule = "cluster-wide-unique";  # via alias
    candidates = [ "session-valkey" ];
    matchedVia = "alias";  # vs "package-type"
    namespace = "data";
  };
};
```

This powers:
- The changeset visualizer (show what resolved where)
- Stability warnings (detect when adding instances changes resolution)
- Debugging ("why does api talk to THAT postgres?")

---

## 12. Summary of Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Fixpoint structure | Flat `{ instanceName -> package }` | Cross-namespace refs are natural; overlays are simple |
| Alias storage | Resolution index only, NOT fixpoint entries | Single identity per instance; overlays unambiguous |
| Alias ownership | Cluster config, not package | Same package can fill different roles in different deployments |
| Resolution order | Explicit > same-ns > cluster-unique > Nix default > error | Mirrors DNS; predictable; local-first |
| `? default` handling | Resolver returns `found=false`; Nix fills in | No AST parsing; leverages Nix semantics |
| `_meta` source | DSL/cluster config (static) | Avoids circular eval in fixpoint |
| Conflict handling | Disambiguate by namespace proximity; error if still ambiguous | No silent shadowing |
| Cross-namespace | Same fixpoint, different `fqdn` values | Transparent; no structural difference |
| Resolution provenance | Recorded per-instance for debugging | Powers changeset viz and stability warnings |

---

## 13. Open Questions for Discussion

### 13.1 Should aliases be ordered (priority)?

Currently all aliases are equal. Should `aliases = [ "sessionStore" "kvStore" ]` mean "prefer sessionStore"? Probably not — the alias is what consumers ask for, not what the provider prefers. But worth considering if edge cases arise.

### 13.2 Wildcard / glob aliases?

Could an instance declare `aliases = [ "*.cache" ]` to match `userCache`, `sessionCache`, etc.? This adds complexity and is probably not worth it. Explicit aliases are clearer.

### 13.3 Alias namespacing?

Should aliases be namespace-scoped? e.g., `aliases = [ "sessionStore" ]` only visible within the same namespace, vs `clusterAliases = [ "sessionStore" ]` visible cluster-wide? The current design treats all aliases as cluster-wide, with namespace proximity as the disambiguation mechanism. This seems sufficient.

### 13.4 Resolution caching across evaluations?

If you run `nix eval` twice with no config changes, resolution should be deterministic (it is — same inputs, same fixpoint). But if config changes, can we cache the parts that didn't change? This is a performance concern for large clusters and may not matter in practice due to Nix's own caching.

### 13.5 How does this interact with the inner fixpoint's `overrideParts`?

If you override a package's inner resource via `overrideParts`, does resolution re-run? No — resolution happens at the outer fixpoint level (which instance fills which role). `overrideParts` operates at the inner fixpoint level (which resources make up an instance). These are orthogonal.
