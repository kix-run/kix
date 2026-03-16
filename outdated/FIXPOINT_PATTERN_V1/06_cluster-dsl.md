# Cluster DSL: Package Sets, Environments, and Composition

## Working Document — March 2026

**Status:** Design exploration (not yet implemented)
**Predecessor:** `04_dependency-injection-and-environments.md` (first environment DSL sketch)

---

## 1. The Problem

The current DSL (from doc 04) works but doesn't flow well:

```nix
{
  namespaces.frontend = {};
  namespaces.backend = {};
  namespaces.data = {};
  services.web-app = { namespace = "frontend"; image = "..."; };
  services.api = { namespace = "backend"; image = "..."; };
  services.postgres = { namespace = "data"; storage = "100Gi"; };
}
```

Issues:
- **Namespaces and services are separate** — you declare namespaces in one place, assign services to them with a string in another. The relationship is implicit.
- **Environments are functions** — `base.withEnvironment { ... }` works but feels like ceremony. You're writing Nix function composition, not thinking about infrastructure.
- **No natural grouping** — related services (backend + its cache) are just flat entries. The structure doesn't reflect how you think about the cluster.
- **Cloning is manual** — running the same services in dev and prod with different configs requires careful merge logic.

This document explores DSL options that feel closer to how you actually think about clusters, while staying raw Nix (no module system, no magic).

---

## 2. The Two Fixpoints — Grounding the DSL

Whatever DSL we pick, it compiles down to the same two fixpoints:

- **Inner** (package level): `lib.fix (self: { deployment = ...; service = ...; main = ...; })` — resources within a package reference each other.
- **Outer** (cluster level): `lib.fix (self: { postgres = ...; myApp = ...; })` — packages within a cluster reference each other.

Everything between the user's DSL and these fixpoints is syntactic sugar. The DSL's job is to produce the outer fixpoint's input: a flat set of `{ name → packageFn + config }` entries.

Namespace objects are themselves entries in the outer fixpoint — they're packages whose "main" is a Namespace resource with `requires` pointing to their policies. A service's `scope` holds a ref to its namespace's `main`, creating an automatic dependency.

This means the DSL needs to produce: `{ instanceName → { package, config, namespace } }` — nothing more.

---

## 3. Approach A: Namespace-Centric Nesting

### The Idea

Group services under their namespace. The namespace *is* the organizational unit.

```nix
mkCluster {
  namespaces = {
    frontend = {
      services.web-app = {
        image = "webapp:v2.1.0";
        replicas = 3;
      };
    };

    backend = {
      services.api = {
        image = "api:v1.5.0";
        replicas = 3;
      };
      services.cache = {
        package = "valkey";
        persistence = false;
      };
    };

    data = {
      resourceQuota.hard."requests.storage" = "500Gi";

      services.postgres = {
        storage = "100Gi";
        version = "16";
      };
      services.session-store = {
        package = "valkey";
        aliases = [ "sessionStore" ];
        sentinel.enabled = true;
      };
    };
  };
}
```

### Flattening

This compiles to the flat outer fixpoint input:

```nix
# Auto-generated from nesting:
{
  "frontend/web-app" = { package = "web-app"; namespace = "frontend"; ... };
  "backend/api"      = { package = "api";     namespace = "backend";  ... };
  "backend/cache"    = { package = "valkey";   namespace = "backend";  ... };
  "data/postgres"    = { package = "postgres"; namespace = "data";     ... };
  "data/session-store" = { package = "valkey"; namespace = "data";     ... };
}
```

Or maybe don't use compound keys — just use the service name as the instance name, and error on collisions:

```nix
{
  web-app = { package = "web-app"; namespace = "frontend"; ... };
  api     = { package = "api";     namespace = "backend";  ... };
  cache   = { package = "valkey";  namespace = "backend";  ... };
  # ...
}
```

### Environments via Namespace Prefixing

```nix
env = name: cluster:
  mapAttrs' (nsName: nsCfg:
    nameValuePair "${name}-${nsName}" nsCfg
  ) cluster.namespaces;

prod = env "prod" (import ./base.nix);
dev  = env "dev"  (import ./base.nix);
# → namespaces: prod-frontend, prod-backend, prod-data
# → namespaces: dev-frontend,  dev-backend,  dev-data
```

### Pros
- Services live where they belong — namespace is structural, not a string field
- Natural grouping of related services with their namespace policies
- Cross-namespace deps are visually obvious (you're referencing something in a different block)
- Namespace prefixing for environments is a trivial `mapAttrs'`

### Cons
- **Services that move namespaces** require restructuring the config, not just changing a field
- **Cross-namespace references** become slightly awkward — you need a way to refer to `data.postgres` from `backend.api`'s config, which the outer fixpoint handles but isn't visible in the DSL
- **Deeply nested** — 3 levels of nesting before you get to a config value (`namespaces.data.services.postgres.storage`)
- **Instance names**: are they `postgres` or `data/postgres`? The namespace is already encoded structurally — repeating it in the name is redundant but might be needed for uniqueness

---

## 4. Approach B: Package Sets as First-Class Values

### The Idea

A package set is a named, composable group of service configs. Think of it like a Nix overlay or a NixOS profile — a reusable unit of "these services, configured this way."

```nix
# A package set is just an attrset of instance configs.
# No namespace assignment yet — that's separate.

corePlatform = {
  postgres = { storage = "100Gi"; version = "16"; };
  valkey = { sentinel.enabled = true; persistence = true; };
};

webStack = {
  web-app = { image = "webapp:v2.1.0"; };
  api = { image = "api:v1.5.0"; };
  api-cache = { package = "valkey"; persistence = false; };
};

monitoring = {
  prometheus = {};
  grafana = {};
  alertmanager = {};
};
```

### Cluster Assembly

```nix
mkCluster {
  # "deploy" assigns package sets to namespaces
  deploy = {
    data = corePlatform;
    backend = webStack;
    monitoring = monitoring;
  };

  # Namespace-level config (policies, quotas) is separate
  namespaces.data.resourceQuota.hard."requests.storage" = "500Gi";
}
```

### Environment Cloning

```nix
# An environment clones a deploy map with a prefix and overrides
mkEnvironment = { name, base, overrides ? {} }:
  let
    prefixed = mapAttrs' (ns: pkgs:
      nameValuePair "${name}-${ns}" pkgs
    ) base.deploy;
  in base // {
    deploy = prefixed // overrides;
  };

prod = mkEnvironment {
  name = "prod";
  base = { deploy = { data = corePlatform; backend = webStack; }; };
  overrides = {
    # Override specific services in specific namespaces
    "prod-backend" = webStack // {
      api = webStack.api // { replicas = 5; };
    };
    "prod-data" = corePlatform // {
      postgres = corePlatform.postgres // { storage = "500Gi"; };
    };
  };
};

dev = mkEnvironment {
  name = "dev";
  base = { deploy = { data = corePlatform; backend = webStack; }; };
  # defaults apply to everything — dev is simple
};
```

### Multi-Cluster / Multi-Env in One File

```nix
# clusters/all.nix — a single file describing all environments
let
  core = { postgres = { storage = "100Gi"; }; valkey = { sentinel = true; }; };
  app  = { api = { image = "api:v1.5"; }; web = { image = "web:v2.1"; }; };
in {
  clusters.dev = mkCluster {
    deploy.default = core // app;
    defaults.replicas = 1;
    autoInstall = true;
  };

  clusters.staging = mkCluster {
    deploy = { data = core; app = app; };
    defaults.replicas = 2;
  };

  clusters.prod = mkCluster {
    deploy = { data = core; app = app; monitoring = monitoring; };
    namespaces.data.networkPolicies = [ /* ... */ ];
    overrides.app.api.replicas = 10;
  };
}
```

### Pros
- **Package sets are reusable** — `corePlatform` is used in dev, staging, and prod
- **Namespace assignment is deployment-time** — postgres doesn't care what namespace it's in, that's decided when you deploy
- **Composition is just `//`** — merge package sets, override individual entries, no special DSL
- **Environment cloning is mechanical** — prefix + override, nothing more
- **Flat within a set** — no deep nesting

### Cons
- **Namespace is not structural** — it's assigned by position in `deploy`, not declared by the service. This means the service doesn't know its namespace until deployment, which is a feature or a bug depending on your perspective.
- **Override ergonomics** — `webStack // { api = webStack.api // { replicas = 5; }; }` is verbose. Need a deep merge or `overrideParts`-like mechanism.
- **Cross-set references** — if `api` (in `webStack`) depends on `postgres` (in `corePlatform`), the resolution system handles it, but the *author* can't see the relationship in the DSL
- **Two concepts to learn**: package sets and deploy maps

---

## 5. Approach C: Flat with Smart Defaults

### The Idea

Keep the flat `services.*` structure but make it less painful with better defaults and grouping sugar.

```nix
mkCluster {
  # Namespaces are declared implicitly by usage, or explicitly for config
  namespaces.data.resourceQuota.hard."requests.storage" = "500Gi";

  # Services are flat. Namespace defaults to the service name's prefix,
  # or must be specified.
  services = {
    # Explicit namespace
    web-app = { namespace = "frontend"; image = "webapp:v2.1.0"; };
    api     = { namespace = "backend";  image = "api:v1.5.0"; };

    # Or use a helper to assign namespace to a group
    ${inNamespace "backend" {
      api-cache = { package = "valkey"; };
    }}

    ${inNamespace "data" {
      postgres = { storage = "100Gi"; };
      session-valkey = { package = "valkey"; aliases = [ "sessionStore" ]; };
    }}
  };
}
```

Wait — `${}` interpolation in attrsets doesn't work like that in Nix. Let me fix this:

```nix
mkCluster {
  namespaces.data.resourceQuota.hard."requests.storage" = "500Gi";

  services =
    {
      web-app = { namespace = "frontend"; image = "webapp:v2.1.0"; };
      api     = { namespace = "backend";  image = "api:v1.5.0"; };
    }
    // inNamespace "backend" {
      api-cache = { package = "valkey"; };
    }
    // inNamespace "data" {
      postgres = { storage = "100Gi"; };
      session-valkey = { package = "valkey"; aliases = [ "sessionStore" ]; };
    };
}
```

Where `inNamespace` is:

```nix
inNamespace = ns: services:
  mapAttrs (_: svc: svc // { namespace = ns; }) services;
```

### Environments

```nix
# clusters/base.nix
base = {
  services =
    { web-app = { namespace = "frontend"; image = "webapp:v2.1.0"; }; }
    // inNamespace "backend" { api = { image = "api:v1.5.0"; }; api-cache = { package = "valkey"; }; }
    // inNamespace "data" { postgres = { storage = "100Gi"; }; };
};

# clusters/prod.nix
prod = base.withOverrides {
  services.api.replicas = 5;
  services.web-app.replicas = 5;
  services.postgres.storage = "500Gi";
  namespaces.data.networkPolicies = [ /* ... */ ];
};

# clusters/dev.nix
dev = base.withOverrides {
  defaults.replicas = 1;
  services.postgres.storage = "10Gi";
};
```

### Pros
- **Minimal new concepts** — it's just attrsets with a helper
- **Flat** — one level of nesting for services
- **`inNamespace` is obvious** — just sets a field, no magic
- **Environment overrides are path-based** — `services.api.replicas = 5` is dead simple

### Cons
- **Still string-based namespaces** — the connection between `namespaces.data` and `inNamespace "data"` is a string, not a structural link
- **`//` merging is fragile** — collision errors are cryptic, and merge order matters for overlapping keys
- **Not as composable as package sets** — you can't easily say "take this group of services and deploy them to a different namespace"

---

## 6. Approach D: Scope Blocks (Hybrid)

### The Idea

Combine structural nesting with flat references. A `scope` block sets defaults for everything inside it.

```nix
mkCluster (cluster: {

  platform = cluster.scope {
    namespace = "platform";
    labels."team" = "platform";
  } {
    coredns = {};
    cert-manager = {};
    ingress-nginx = {};
  };

  data = cluster.scope {
    namespace = "data";
    resourceQuota.hard."requests.storage" = "500Gi";
  } {
    postgres = { storage = "100Gi"; version = "16"; };
    session-store = { package = "valkey"; aliases = [ "sessionStore" ]; };
  };

  backend = cluster.scope {
    namespace = "backend";
  } {
    api = {
      image = "api:v1.5.0";
      replicas = 3;
    };
    cache = { package = "valkey"; persistence = false; };
  };

  frontend = cluster.scope {
    namespace = "frontend";
  } {
    web-app = {
      image = "webapp:v2.1.0";
      replicas = 3;
    };
  };

})
```

`cluster.scope` takes defaults and a set of services, returns them with defaults applied. The scope names (`platform`, `data`, `backend`, `frontend`) are just grouping labels — the namespace comes from the scope config.

### What `scope` Returns

```nix
cluster.scope = defaults: services:
  mapAttrs (name: svc: {
    inherit name;
    namespace = defaults.namespace;
    labels = (defaults.labels or {}) // (svc.labels or {});
  } // svc) services;
```

The return value is a flat attrset of instance configs — it feeds directly into the outer fixpoint.

### Environments

```nix
# clusters/base.nix
base = cluster: {
  data = cluster.scope { namespace = "data"; } {
    postgres = { storage = "100Gi"; };
  };
  backend = cluster.scope { namespace = "backend"; } {
    api = { image = "api:v1.5.0"; };
  };
};

# Environment = prefix namespaces + override
prod = cluster:
  let b = base cluster;
  in cluster.env "prod" b {
    # cluster.env prefixes all namespace names: data → prod-data, backend → prod-backend
    # Then applies these overrides:
    data.postgres.storage = "500Gi";
    backend.api.replicas = 5;
  };

dev = cluster:
  let b = base cluster;
  in cluster.env "dev" b {
    defaults.replicas = 1;
    data.postgres.storage = "10Gi";
  };
```

`cluster.env` does three things:
1. Prefixes all namespace names: `data` → `prod-data`
2. Deep-merges overrides
3. Returns the same shape (flat attrset of instance configs)

### Multi-Env Cluster

```nix
# When you want dev and staging in the same physical cluster:
mkCluster (cluster:
  (cluster.env "staging" (base cluster) {
    backend.api.replicas = 2;
  })
  //
  (cluster.env "dev" (base cluster) {
    defaults.replicas = 1;
  })
)
# → namespaces: staging-data, staging-backend, dev-data, dev-backend
# → all in one cluster, namespace-isolated
```

### Pros
- **Scope is just defaults** — no magic, no module system, just "set these fields on everything inside"
- **Grouping is structural** — services in the same scope are visually together
- **Environment prefixing is first-class** — `cluster.env` does the mechanical work
- **Multi-env in one cluster** is natural — just `//` two envs
- **Compiles to flat** — `scope` returns `{ name → config }`, which is exactly what the fixpoint needs

### Cons
- **Scope names vs namespace names** — the scope group name (`data`) and the namespace name (`data`) are different concepts that often coincide. If they diverge it's confusing.
- **`cluster` parameter threading** — the `cluster:` function argument is needed for `cluster.scope` and `cluster.env`, which means the config is a function, not plain data. This makes it harder to inspect/merge from the outside.
- **Override syntax**: `data.postgres.storage = "500Gi"` looks like a path into the scope groups, but it's actually a deep-merge into the instance config. Could be confusing.

---

## 7. Approach E: Just Functions (The Unix Way)

### The Idea

Don't design a DSL. Provide small composable functions. The user writes whatever Nix they want.

```nix
let
  k = import ./kixpkgs;

  # Helper: assign namespace to a group of instances
  ns = k.inNamespace;

  # Helper: prefix all namespaces in a set
  env = k.prefixEnv;

  # Helper: deep merge with overrides
  over = k.lib.recursiveUpdate;

  # The actual services — plain attrsets
  data = ns "data" {
    postgres = { storage = "100Gi"; version = "16"; };
    session = { package = "valkey"; aliases = [ "sessionStore" ]; };
  };

  backend = ns "backend" {
    api = { image = "api:v1.5.0"; };
    cache = { package = "valkey"; };
  };

  frontend = ns "frontend" {
    web = { image = "webapp:v2.1.0"; };
  };

  all = data // backend // frontend;

in {
  dev = k.mkCluster (env "dev" (over all {
    postgres.storage = "10Gi";
  }) // { _defaults.replicas = 1; });

  prod = k.mkCluster (env "prod" (over all {
    api.replicas = 5;
    web.replicas = 5;
    postgres.storage = "500Gi";
  }));
}
```

### The Functions

```nix
inNamespace = ns: services:
  mapAttrs (_: svc: svc // { namespace = ns; }) services;

prefixEnv = prefix: services:
  mapAttrs (_: svc: svc // {
    namespace = "${prefix}-${svc.namespace}";
  }) services;

mkCluster = instances:
  let
    defaults = instances._defaults or {};
    real = removeAttrs instances [ "_defaults" ];
    withDefaults = mapAttrs (_: svc: defaults // svc) real;
  in buildCluster withDefaults;
```

### Pros
- **No DSL to learn** — it's just Nix
- **Maximum flexibility** — the user composes however they want
- **Tiny API surface** — `inNamespace`, `prefixEnv`, `mkCluster`, done
- **Everything is inspectable** — `all` is a plain attrset you can print, diff, filter
- **Environments are just function application** — no special mechanism

### Cons
- **No guardrails** — typos in service names are just silent attrset entries
- **Override ergonomics** — `over all { api.replicas = 5; }` only works one level deep. For deeper merges you need `lib.recursiveUpdate` which has its own gotchas (it merges everything, including things you might want to replace).
- **No structural validation** — nothing stops you from writing `{ postgres = "banana"; }` until eval time
- **Every user invents their own patterns** — without conventions, every cluster config looks different

---

## 8. Comparison Matrix

| Concern | A: Nested | B: Package Sets | C: Flat+Helpers | D: Scope Blocks | E: Just Functions |
|---|---|---|---|---|---|
| Grouping | structural (ns) | by set | manual (`//`) | by scope | manual |
| Namespace assignment | structural | by deploy map | string field | scope default | helper fn |
| Env cloning | prefix ns names | prefix deploy keys | `withOverrides` | `cluster.env` | `prefixEnv` |
| Override ergonomics | deep path | `//` merge | path-based | deep merge | `recursiveUpdate` |
| Composability | limited | high | medium | high | highest |
| Discoverability | good (nested) | good (named sets) | ok | good | poor |
| New concepts | nesting rules | package sets, deploy maps | helpers | scope, env | just nix |
| Multi-env in one cluster | prefix | prefix deploy keys | manual | `//` two envs | `//` two envs |
| Cross-ns visibility | need to escape nesting | flat within set | flat | flat within scope | flat |

---

## 9. My Recommendation: Start with E, Graduate to D

**E (Just Functions)** is the right starting point because:
- It forces you to discover the real pain points before designing abstractions
- Every helper you add is driven by actual need, not speculation
- The functions (`inNamespace`, `prefixEnv`, `mkCluster`) are so simple they're obviously correct

**D (Scope Blocks)** is where you graduate when:
- You find yourself repeating the same `inNamespace` + labels + quotas pattern
- You want `cluster.env` to handle more than just prefixing (e.g., auto-adjusting resource quotas)
- You want the cluster object to carry validation logic

The key insight: D is just E with `cluster.scope` being a slightly richer `inNamespace`. You can build D on top of E without breaking anything.

**Avoid A (Namespace-Centric Nesting)** — it looks clean for small examples but falls apart when services move namespaces, when you need cross-namespace references in config, or when you want to reuse service groups across environments.

**B (Package Sets)** is interesting for large organizations where teams own package sets. Worth revisiting when kixpkgs hits that scale, but premature now.

---

## 10. Open Questions

### 10.1 Namespace as scope vs namespace as resource
In all approaches, the namespace serves double duty: it's a grouping concept in the DSL AND a Kubernetes resource in the output. When you write `inNamespace "data"`, are you saying "these services go in namespace data" or "these services depend on the data Namespace resource"? Both — and the system handles it. But should the DSL make this distinction visible?

### 10.2 Environment prefixing: shallow or deep?
`prefixEnv "prod"` turns `namespace = "data"` into `namespace = "prod-data"`. But should it also prefix instance names? Service FQDNs? Labels? The answer affects cross-environment references (can staging-api talk to prod-postgres?).

### 10.3 Defaults precedence
With `_defaults` or scope defaults, what's the merge order? Should scope defaults override service-specific values, or vice versa? Service-specific should always win — defaults are just that, defaults.

### 10.4 Where does namespace config live?
Resource quotas, network policies, limit ranges — these are namespace-level concerns. In approach A they live inside the namespace block. In E they need a separate mechanism:

```nix
# Option 1: alongside services
k.mkCluster (all // {
  _namespaces.data.resourceQuota = "...";
})

# Option 2: as special services
k.mkCluster (all // {
  data-ns = { _type = "namespace"; resourceQuota = "..."; };
})

# Option 3: separate arg to mkCluster
k.mkCluster {
  services = all;
  namespaces.data.resourceQuota = "...";
}
```

Option 3 is cleanest but means `mkCluster` takes a structured arg instead of a flat attrset.

### 10.5 How does this interact with auto-install (doc 05)?
If auto-install creates a postgres, which namespace does it go in? The DSL needs to either:
- Let the package declare a default namespace (package-driven)
- Let the cluster config specify defaults for auto-installed packages
- Put auto-installed packages in the requester's scope/namespace

This interacts with the scope/grouping mechanism — an auto-installed package should appear in the right group, not float in limbo.
