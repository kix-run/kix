# Team DX: Cluster Definition, Multi-Deploy, and Composition

## Working Document -- March 2026

**Status:** Design exploration (not yet implemented)
**Predecessors:** `06_cluster-dsl.md` (DSL approaches), `04_dependency-injection-and-environments.md` (env variants), `05_auto-install.md`

---

## 1. Scope

This document works through the concrete developer experience of teams defining and composing clusters. It builds on the DSL exploration in doc 06, which recommended "start with E (Just Functions), graduate to D (Scope Blocks)." Here we take that recommendation and push it through real scenarios:

- A team's cluster definition file
- Multi-deploy: same services in dev and prod namespaces within one cluster
- Multi-team composition and namespace sharing
- Override patterns at every level
- Environment-specific config imports

The focus is on what the code looks like, what feels natural, and where raw Nix falls short.

---

## 2. The Primitives

The entire user-facing API consists of four things:

```nix
# From kixpkgs
{
  mkCluster    : { services, namespaces?, defaults? } -> cluster
  inNamespace  : string -> serviceSet -> serviceSet
  prefixEnv    : string -> serviceSet -> serviceSet
  lib          : { recursiveUpdate, ... }
}
```

`mkCluster` takes a flat set of instance configs (plus optional namespace config and defaults) and produces the outer fixpoint. Everything else is plain Nix -- attrset merges, functions, `let` bindings.

No special DSL syntax. No module system. No `mkOption`, no `config`, no `imports`.

---

## 3. A Team's Cluster Definition File

### 3.1 The Simplest Case

Team Backend owns three services. They write one file:

```nix
# teams/backend/cluster.nix
{ kix }:

let
  ns = kix.inNamespace;
in {
  services =
    ns "backend" {
      api = {
        image = "api:v1.5.0";
        replicas = 3;
      };
      worker = {
        image = "worker:v1.5.0";
        replicas = 2;
      };
      cache = {
        package = "valkey";
        persistence = false;
      };
    }
    // ns "data" {
      postgres = {
        storage = "100Gi";
        version = "16";
      };
    };

  namespaces.data = {
    resourceQuota.hard."requests.storage" = "500Gi";
  };
}
```

What the team typed: 20 lines of actual config. What they get: four fully-wired packages with dependency resolution, namespace resources, deploy ordering, and reachability checking.

Key properties:
- `api` and `worker` both get `cache` (same namespace, package type "valkey") automatically via DNS-like resolution (doc 04)
- Both get `postgres` automatically (unique cluster-wide)
- No wiring boilerplate -- the package functions declare their args, the system resolves them
- `package = "valkey"` selects the kixpkgs package; omitting it means the instance name IS the package name

### 3.2 Choosing and Configuring Packages

Packages come from the kixpkgs package set. Configuration is the package's `config` argument -- each package defines what it accepts:

```nix
# Selecting a package explicitly (instance name differs from package name)
session-store = {
  package = "valkey";
  aliases = [ "sessionStore" ];  # discoverable by role name
  sentinel.enabled = true;
  persistence.enabled = true;
};

# Instance name = package name (common case)
postgres = {
  storage = "100Gi";
  version = "16";
};

# Overriding the image (every package accepts this)
api = {
  image = "registry.internal/api:v1.5.0";
  replicas = 3;
};
```

No schema validation at declaration time -- the package function will error at eval time if you pass config it doesn't understand. This is the tradeoff of "no module system": you lose early validation but gain simplicity. The error messages from Nix are "unexpected argument 'stoarge'" which is clear enough.

### 3.3 Custom Inline Packages

Teams can define packages inline without adding them to the kixpkgs package set:

```nix
# teams/backend/cluster.nix
{ kix }:

let
  ns = kix.inNamespace;

  # A one-off CronJob that doesn't warrant a kixpkgs package
  dbMigrator = { scope, config, postgres }:
    self: {
      job = scope.mkResource {
        apiVersion = "batch/v1";
        kind = "CronJob";
        name = "db-migrator";
        spec = {
          schedule = config.schedule or "0 3 * * *";
          jobTemplate.spec.template.spec.containers = [{
            name = "migrate";
            image = config.image;
            env = [{
              name = "DATABASE_URL";
              value = scope.str [ "postgresql://" postgres.fqdn ":5432/mydb" ];
            }];
          }];
        };
      };
      main = self.job;
    };

in {
  services =
    ns "backend" {
      api = { image = "api:v1.5.0"; };
    }
    // ns "data" {
      postgres = { storage = "100Gi"; };
      db-migrator = {
        package = dbMigrator;  # inline function, not a string
        image = "db-migrator:v1.0.0";
        schedule = "0 2 * * *";
      };
    };
}
```

When `package` is a function instead of a string, `mkCluster` uses it directly instead of looking it up in the registry. The inline package participates in the fixpoint like any other -- it gets `postgres` resolved automatically.

---

## 4. Multi-Deploy: Dev and Prod from the Same Definition

### 4.1 The Core Problem

You have a set of services -- say, the backend stack. You want to deploy it twice in the same cluster: once in `dev-*` namespaces with dev settings, once in `prod-*` namespaces with prod settings. Each deploy is isolated: dev-api talks to dev-postgres, prod-api talks to prod-postgres.

### 4.2 Package Sets: Reusable Groups

A "package set" is just an attrset of instance configs. No special type:

```nix
# teams/backend/services.nix
#
# The canonical definition of what the backend team runs.
# No namespace assignment -- that's a deployment concern.
# No environment-specific config -- that's an overlay concern.
{ kix }:

{
  backendStack = {
    api = { image = "api:v1.5.0"; replicas = 3; };
    worker = { image = "worker:v1.5.0"; replicas = 2; };
    cache = { package = "valkey"; persistence = false; };
  };

  dataStack = {
    postgres = { storage = "100Gi"; version = "16"; };
    session-store = {
      package = "valkey";
      aliases = [ "sessionStore" ];
      sentinel.enabled = true;
    };
  };
}
```

These are plain attrsets. No `mkPackageSet`, no wrappers. You can merge them (`//`), filter them (`removeAttrs`), map over them (`mapAttrs`). They're data.

### 4.3 Deploying a Package Set to a Namespace

```nix
# "deploy" is just inNamespace
deploy = name: set: kix.inNamespace name set;

# Produces: { api = { ...; namespace = "backend"; }; worker = { ...; namespace = "backend"; }; ... }
deploy "backend" backendStack
```

### 4.4 Multi-Deploy with Environment Prefixing

```nix
# teams/backend/cluster.nix
{ kix }:

let
  inherit (import ./services.nix { inherit kix; }) backendStack dataStack;

  ns = kix.inNamespace;
  env = kix.prefixEnv;
  over = kix.lib.recursiveUpdate;

  # The base deployment: services assigned to namespaces
  base =
    ns "backend" backendStack
    // ns "data" dataStack;

in {
  services =
    # Dev deploy: prefix all namespaces with "dev-", apply dev overrides
    env "dev" (over base {
      api.replicas = 1;
      worker.replicas = 1;
      postgres.storage = "10Gi";
    })
    //
    # Prod deploy: prefix all namespaces with "prod-", apply prod overrides
    env "prod" (over base {
      api.replicas = 5;
      worker.replicas = 3;
      postgres.storage = "500Gi";
      postgres.backup.enabled = true;
    });

  namespaces = {
    prod-data.resourceQuota.hard."requests.storage" = "1Ti";
    prod-data.networkPolicies = [{ /* lock down */ }];
    # dev namespaces get no policies -- open by default
  };
}
```

What `prefixEnv` does:

```nix
prefixEnv = prefix: services:
  mapAttrs (name: svc: svc // {
    namespace = "${prefix}-${svc.namespace}";
    # Also prefix the instance name to avoid collisions
  }) services;
```

But wait -- if both `env "dev"` and `env "prod"` produce instances named `api`, they collide in the flat attrset merge (`//`). The instance names need prefixing too.

### 4.5 The Instance Name Problem

`prefixEnv` must also prefix instance names:

```nix
prefixEnv = prefix: services:
  lib.mapAttrs' (name: svc:
    lib.nameValuePair "${prefix}-${name}" (svc // {
      namespace = "${prefix}-${svc.namespace}";
    })
  ) services;
```

Now the merge works:

```nix
env "dev" base // env "prod" base
# → {
#   dev-api     = { namespace = "dev-backend";  ... };
#   dev-worker  = { namespace = "dev-backend";  ... };
#   dev-postgres = { namespace = "dev-data";    ... };
#   prod-api    = { namespace = "prod-backend"; ... };
#   prod-worker = { namespace = "prod-backend"; ... };
#   prod-postgres = { namespace = "prod-data";  ... };
# }
```

### 4.6 Cross-References in Multi-Deploy

This is the critical question: when `dev-api` resolves its `postgres` dependency, does it find `dev-postgres` or `prod-postgres`?

DNS-like resolution (doc 04) handles this correctly:

1. `dev-api` is in namespace `dev-backend`
2. Resolution looks for `postgres` (package type) in namespace `dev-backend` -- not found
3. Resolution looks cluster-wide -- finds both `dev-postgres` (ns: `dev-data`) and `prod-postgres` (ns: `prod-data`)
4. Ambiguous? Yes, unless reachability or namespace affinity breaks the tie

This is a problem. With two environments in one cluster, every dependency becomes ambiguous. Two solutions:

**Solution A: Explicit dependency wiring per environment**

```nix
env "dev" (over base {
  api.postgres = "dev-postgres";   # explicit instance name
})
```

This defeats the purpose of auto-resolution. Verbose, fragile.

**Solution B: Environment-scoped resolution**

The system treats environment-prefixed instances as a resolution group. When resolving deps for `dev-api`, the resolver first looks within the `dev-*` instances, then falls back to unprefixed (shared) instances.

```nix
prefixEnv = prefix: services:
  lib.mapAttrs' (name: svc:
    lib.nameValuePair "${prefix}-${name}" (svc // {
      namespace = "${prefix}-${svc.namespace}";
      _envScope = prefix;  # resolution hint
    })
  ) services;
```

Resolution order for `dev-api` requesting `postgres`:
1. Same namespace (`dev-backend`): any instance with package type `postgres`? No.
2. Same env scope (`dev-*`): `dev-postgres` (type match). Yes -- use it.
3. Cluster-wide (unprefixed instances only): shared services.

This preserves the DNS-like mental model. Within an environment, everything just works. Cross-environment references require explicit wiring (which is correct -- you should be explicit when dev-api talks to prod-postgres).

**Solution C: Package sets carry their own resolution scope**

Instead of relying on the outer fixpoint for intra-environment resolution, make `prefixEnv` create a scoped mini-fixpoint. Each environment's services resolve against each other first, then against the cluster.

This is more complex to implement but makes the isolation guarantee structural rather than conventional.

**Recommendation:** Solution B. It's a small extension to the existing resolver (one extra field, one extra resolution step) and it correctly models the intent: services in the same environment prefer each other.

### 4.7 Override Ergonomics

`recursiveUpdate` is the standard Nix deep merge, but it has a well-known gotcha: it merges all the way down, including things you might want to replace (lists, leaf attrsets). For cluster config this is usually fine because most values are scalars, but it's worth noting.

For a more surgical approach, individual service overrides:

```nix
# Override one service in a package set
prodBackend = backendStack // {
  api = backendStack.api // { replicas = 5; };
};
```

This is verbose. A `withOverrides` helper is tempting:

```nix
withOverrides = base: overrides:
  lib.mapAttrs (name: svc:
    if overrides ? ${name}
    then svc // overrides.${name}
    else svc
  ) base;

prodBackend = withOverrides backendStack {
  api = { replicas = 5; };
  worker = { replicas = 3; };
};
```

Shallow merge per service is the right default -- you're overriding config fields, not deep-merging nested structures. If a service config has nested attrsets (like `sentinel.enabled`), you'd write `session-store = { sentinel.enabled = true; }` and it would replace the whole `sentinel` attr. But `session-store` already had `sentinel.enabled = true` in the base, so this is fine -- overrides are additive in practice.

For the rare case where you need deep merge on a specific service:

```nix
prodBackend = withOverrides backendStack {
  postgres = lib.recursiveUpdate backendStack.postgres {
    backup = { enabled = true; schedule = "0 */6 * * *"; };
  };
};
```

Explicit, clear, no magic.

---

## 5. Multi-Team Composition

### 5.1 Each Team Produces a Fragment

```nix
# teams/backend/cluster.nix
{ kix }: {
  services = kix.inNamespace "backend" { api = { ... }; worker = { ... }; };
  namespaces.backend = {};
}

# teams/frontend/cluster.nix
{ kix }: {
  services = kix.inNamespace "frontend" { web-app = { ... }; };
  namespaces.frontend = {};
}

# teams/platform/cluster.nix
{ kix }: {
  services = kix.inNamespace "platform" { coredns = {}; cert-manager = {}; ingress-nginx = {}; };
  namespaces.platform = {};
}
```

### 5.2 Cluster Assembly: `evaluateCluster`

```nix
# cluster.nix — the top-level file that combines all teams
{ kix }:

let
  backend  = import ./teams/backend/cluster.nix  { inherit kix; };
  frontend = import ./teams/frontend/cluster.nix { inherit kix; };
  platform = import ./teams/platform/cluster.nix { inherit kix; };

  # Environment-specific values
  envConfig = import ./envs/${builtins.getEnv "CLUSTER_ENV" or "dev"}.nix;

in kix.mkCluster {
  # Services: merge all team fragments
  services =
    backend.services
    // frontend.services
    // platform.services;

  # Namespaces: deep merge (policies accumulate)
  namespaces = kix.lib.recursiveUpdate
    (kix.lib.recursiveUpdate backend.namespaces frontend.namespaces)
    platform.namespaces;

  # Environment-level defaults
  defaults = envConfig.defaults or {};
}
```

Collision detection: `//` silently overwrites on key collision. If team A and team B both define a service named `cache`, the second one wins. This is a real risk.

### 5.3 Collision Detection

Two options:

**Option A: Convention -- prefix service names with team name**

```nix
# teams/backend/cluster.nix
services = ns "backend" {
  backend-cache = { package = "valkey"; };  # team prefix in name
};
```

Simple, but pollutes names.

**Option B: `mkCluster` validates no collisions**

```nix
mkCluster = { services, ... }:
  let
    # Check for duplicate keys across team fragments
    # (This requires teams to pass fragments as a list, not pre-merged)
  in ...;
```

Better version -- accept a list of fragments:

```nix
kix.mkCluster {
  fragments = [ backend frontend platform ];
  defaults = envConfig.defaults or {};
}
```

Where `mkCluster` merges services and checks for collisions:

```nix
mkCluster = { fragments, ... }:
  let
    allServices = lib.foldl' (acc: frag:
      let collisions = builtins.intersectAttrs acc frag.services;
      in if collisions != {} then
        throw "service name collision: ${toString (attrNames collisions)}"
      else acc // frag.services
    ) {} fragments;
  in buildCluster { services = allServices; ... };
```

This catches collisions at eval time with a clear error. The cost: teams pass fragments as structured values, not pre-merged attrsets.

### 5.4 Shared Namespaces

Team A and team B both deploy services into `shared-infra`. How does this work?

```nix
# teams/monitoring/cluster.nix
{ kix }: {
  services = kix.inNamespace "shared-infra" {
    prometheus = {};
    grafana = {};
  };
  namespaces.shared-infra = {
    resourceQuota.hard."requests.cpu" = "20";
  };
}

# teams/logging/cluster.nix
{ kix }: {
  services = kix.inNamespace "shared-infra" {
    elasticsearch = { storage = "200Gi"; };
    kibana = {};
  };
  namespaces.shared-infra = {
    resourceQuota.hard."requests.memory" = "64Gi";
  };
}
```

After merging with `recursiveUpdate`, the namespace config becomes:

```nix
namespaces.shared-infra = {
  resourceQuota.hard."requests.cpu" = "20";
  resourceQuota.hard."requests.memory" = "64Gi";
};
```

This works for additive config (quotas, labels). It breaks for list-valued config (networkPolicies) because `recursiveUpdate` replaces lists, it doesn't concatenate them.

**Solution: namespace config uses attrsets everywhere, not lists**

```nix
# Instead of:
namespaces.shared-infra.networkPolicies = [ policy1 policy2 ];

# Use named policies:
namespaces.shared-infra.networkPolicies.monitoring-ingress = { /* ... */ };
namespaces.shared-infra.networkPolicies.logging-ingress = { /* ... */ };
```

Named policies merge naturally with `//` and `recursiveUpdate`. Team A adds `monitoring-ingress`, team B adds `logging-ingress`, both survive the merge. This is the same insight as NixOS's named systemd units -- names make things mergeable.

### 5.5 Can a Team Add Policies to Another Team's Namespace?

Yes, because namespace config is just attrsets that get merged:

```nix
# teams/security/cluster.nix
{ kix }: {
  services = {};  # no services, just policies
  namespaces = {
    backend.networkPolicies.deny-egress = { /* ... */ };
    frontend.networkPolicies.deny-egress = { /* ... */ };
    data.networkPolicies.deny-all-ingress = { /* ... */ };
  };
}
```

The security team doesn't own any namespace but adds policies to all of them. This composes naturally because policies are named attrsets -- security's `deny-egress` merges alongside backend's own policies.

---

## 6. Override Patterns

### 6.1 Override a Package's Config (replicas, image)

```nix
# At definition time
services = ns "backend" {
  api = { image = "api:v1.5.0"; replicas = 3; };
};

# At environment time
env "prod" (over base {
  api.replicas = 5;
  api.image = "api:v1.6.0";
})
```

Shallow. The service config is a flat attrset -- `//` or `recursiveUpdate` both work.

### 6.2 Override a Package's Internal Resources (`overrideParts`)

Sometimes you need to change something inside the package -- swap a Deployment for a StatefulSet, add a sidecar container. Config fields can't express this. `overrideParts` operates on the inner fixpoint:

```nix
services = ns "backend" {
  api = {
    image = "api:v1.5.0";
    overrideParts = self: super: {
      deployment = super.deployment.override {
        spec.template.spec.containers = super.deployment.spec.template.spec.containers ++ [{
          name = "sidecar";
          image = "envoy:v1.28";
        }];
      };
    };
  };
};
```

`overrideParts` is passed through `config` to the package instantiation. The inner fixpoint applies it after the package's own definition, so `super` has the original resources and `self` has the final ones.

This is the escape hatch -- when config isn't enough, you operate on the resource DAG directly.

### 6.3 Cluster-Wide Overrides

"All postgres instances in this cluster get `backup.enabled = true`":

```nix
# cluster.nix
kix.mkCluster {
  services = allServices;

  # Type-level defaults: applied to every instance whose package type matches
  packageDefaults.postgres = {
    backup.enabled = true;
    backup.schedule = "0 */6 * * *";
  };

  packageDefaults.valkey = {
    maxmemory-policy = "allkeys-lru";
  };
}
```

Implementation in `mkCluster`:

```nix
mkCluster = { services, packageDefaults ? {}, ... }:
  let
    withPkgDefaults = mapAttrs (name: svc:
      let
        pkgType = svc.package or name;
        defaults = packageDefaults.${pkgType} or {};
      in defaults // svc  # service-specific config wins
    ) services;
  in buildCluster { services = withPkgDefaults; ... };
```

Precedence (lowest to highest):
1. Package's built-in defaults (in the package function's `config` handling)
2. `packageDefaults` (cluster-wide, by package type)
3. `defaults` (environment-wide, all services)
4. Service instance config (explicit per-service)
5. `overrideParts` (inner fixpoint, structural)

### 6.4 External Variable Imports

```nix
# envs/prod.nix
{
  defaults = {
    replicas = 3;
  };

  images = {
    api = "registry.internal/api:v1.6.0-rc2";
    worker = "registry.internal/worker:v1.6.0-rc2";
    web-app = "registry.internal/web-app:v2.2.0";
  };

  storage = {
    postgres = "500Gi";
  };
}

# envs/dev.nix
{
  defaults = {
    replicas = 1;
  };

  images = {
    api = "api:latest";
    worker = "worker:latest";
    web-app = "web-app:latest";
  };

  storage = {
    postgres = "10Gi";
  };
}
```

Usage:

```nix
# cluster.nix
let
  envConfig = import ./envs/${env}.nix;
in {
  services = ns "backend" {
    api = {
      image = envConfig.images.api;
      replicas = envConfig.defaults.replicas;
    };
  }
  // ns "data" {
    postgres = {
      storage = envConfig.storage.postgres;
    };
  };
}
```

This is ordinary Nix `import`. No special mechanism. The env file is a plain attrset. You could also source values from JSON, TOML, or whatever Nix can read (`builtins.fromJSON (builtins.readFile ./versions.json)`).

For secrets, the env file doesn't contain the secret -- it contains a reference to where the secret lives:

```nix
# envs/prod.nix
{
  secrets.database-password = {
    source = "vault";
    path = "secret/data/prod/postgres";
    key = "password";
  };
}
```

The package uses this to generate a SecretProviderClass or ExternalSecret resource, not to inline the value.

---

## 7. Environment-Specific Config: Staying DRY

### 7.1 The Pattern: Base + Env Overlay

```nix
# teams/backend/services.nix -- the base, shared across all envs
{ kix }:
let
  ns = kix.inNamespace;
in
  ns "backend" {
    api = { image = "api:v1.5.0"; };
    worker = { image = "worker:v1.5.0"; };
    cache = { package = "valkey"; };
  }
  // ns "data" {
    postgres = { storage = "100Gi"; };
  }
```

```nix
# teams/backend/cluster.nix -- environment-aware entry point
{ kix, env ? "dev" }:

let
  base = import ./services.nix { inherit kix; };
  envOverrides = import ./envs/${env}.nix;
  over = kix.lib.recursiveUpdate;
in {
  services = over base envOverrides.services or {};
  namespaces = envOverrides.namespaces or {};
}
```

```nix
# teams/backend/envs/prod.nix
{
  services = {
    api.replicas = 5;
    api.image = "api:v1.6.0";
    worker.replicas = 3;
    postgres.storage = "500Gi";
    postgres.backup.enabled = true;
  };
  namespaces.data = {
    resourceQuota.hard."requests.storage" = "1Ti";
    networkPolicies.backend-only = { /* ... */ };
  };
}
```

```nix
# teams/backend/envs/dev.nix
{
  services = {
    api.replicas = 1;
    worker.replicas = 1;
    postgres.storage = "10Gi";
  };
}
```

The base file has everything. The env files have only differences. Adding a new service to the base automatically includes it in all environments.

### 7.2 Multi-Deploy (dev + prod in same cluster) with DRY Config

```nix
# teams/backend/cluster.nix -- for shared clusters
{ kix }:

let
  base = import ./services.nix { inherit kix; };
  devOverrides  = import ./envs/dev.nix;
  prodOverrides = import ./envs/prod.nix;

  env = kix.prefixEnv;
  over = kix.lib.recursiveUpdate;

in {
  services =
    env "dev"  (over base (devOverrides.services or {}))
    // env "prod" (over base (prodOverrides.services or {}));

  namespaces =
    # Prefix namespace names to match prefixEnv
    kix.lib.mapAttrs' (name: val:
      kix.lib.nameValuePair "prod-${name}" val
    ) (prodOverrides.namespaces or {});
}
```

One base definition. Two env overlays. Both deployed to the same cluster with namespace isolation. The env overlay files are reused whether you're doing multi-deploy (same cluster) or multi-cluster (separate clusters).

---

## 8. Concrete Code: Full evaluateCluster Call

### 8.1 Repository Layout

```
clusters/
  shared-dev-prod/
    cluster.nix          # top-level composition
    envs/
      dev.nix
      prod.nix
teams/
  backend/
    cluster.nix          # team's fragment
    services.nix         # package set definitions
    envs/
      dev.nix
      prod.nix
  frontend/
    cluster.nix
    services.nix
  platform/
    cluster.nix
```

### 8.2 Top-Level Cluster File

```nix
# clusters/shared-dev-prod/cluster.nix
#
# A single physical cluster running dev and prod side by side.
# Each team contributes a fragment. Each fragment is deployed
# twice -- once with dev- prefix, once with prod- prefix.
{ kix }:

let
  backend  = import ../../teams/backend/cluster.nix  { inherit kix; };
  frontend = import ../../teams/frontend/cluster.nix { inherit kix; };
  platform = import ../../teams/platform/cluster.nix { inherit kix; };

in kix.mkCluster {
  # Each team fragment already contains env-prefixed services
  fragments = [ backend frontend platform ];

  # Cluster-wide settings
  packageDefaults.postgres = {
    backup.enabled = true;
  };
}
```

### 8.3 A Team's Fragment (Multi-Deploy)

```nix
# teams/backend/cluster.nix
{ kix }:

let
  base = import ./services.nix { inherit kix; };

  devCfg  = import ./envs/dev.nix;
  prodCfg = import ./envs/prod.nix;

  env = kix.prefixEnv;
  over = kix.lib.recursiveUpdate;

  # withOverrides: shallow merge per service (not deep)
  withOverrides = base: overrides:
    lib.mapAttrs (name: svc:
      if overrides ? ${name}
      then svc // overrides.${name}
      else svc
    ) base;
in {
  services =
    env "dev"  (withOverrides base devCfg.serviceOverrides)
    // env "prod" (withOverrides base prodCfg.serviceOverrides);

  namespaces =
    let prefixNs = prefix: lib.mapAttrs' (n: v: lib.nameValuePair "${prefix}-${n}" v);
    in (prefixNs "dev" (devCfg.namespaces or {}))
       // (prefixNs "prod" (prodCfg.namespaces or {}));
}
```

### 8.4 Package Set

```nix
# teams/backend/services.nix
{ kix }:

let ns = kix.inNamespace;
in
  ns "backend" {
    api = {
      image = "api:v1.5.0";
      replicas = 3;
    };
    worker = {
      image = "worker:v1.5.0";
      replicas = 2;
    };
    cache = {
      package = "valkey";
      persistence = false;
    };
  }
  // ns "data" {
    postgres = {
      storage = "100Gi";
      version = "16";
    };
    session-store = {
      package = "valkey";
      aliases = [ "sessionStore" ];
      sentinel.enabled = true;
    };
  }
```

### 8.5 Environment Overrides

```nix
# teams/backend/envs/dev.nix
{
  serviceOverrides = {
    api      = { replicas = 1; image = "api:latest"; };
    worker   = { replicas = 1; image = "worker:latest"; };
    postgres = { storage = "10Gi"; };
    session-store = { sentinel.enabled = false; };
  };
}

# teams/backend/envs/prod.nix
{
  serviceOverrides = {
    api    = { replicas = 5; };
    worker = { replicas = 3; };
    postgres = {
      storage = "500Gi";
      backup.enabled = true;
      backup.schedule = "0 */6 * * *";
    };
  };

  namespaces = {
    data = {
      resourceQuota.hard."requests.storage" = "1Ti";
      networkPolicies.backend-only = {
        podSelector = {};
        policyTypes = [ "Ingress" ];
        ingress = [{
          from = [{ namespaceSelector.matchLabels."env/ns" = "prod-backend"; }];
        }];
      };
    };
    backend = {
      networkPolicies.frontend-and-monitoring = {
        podSelector = {};
        policyTypes = [ "Ingress" ];
        ingress = [{
          from = [
            { namespaceSelector.matchLabels."env/ns" = "prod-frontend"; }
            { namespaceSelector.matchLabels."app" = "monitoring"; }
          ];
        }];
      };
    };
  };
}
```

---

## 9. Design Tensions and Open Questions

### 9.1 Instance Name Prefixing in Multi-Deploy

`prefixEnv` renames `api` to `dev-api` and `prod-api`. This means:

- The package's `scope.instanceName` becomes `dev-api`, which affects the K8s resource names
- K8s service names become `dev-api.dev-backend.svc.cluster.local`
- Helm-style naming conventions (just `api`) are broken

Is this right? In a shared cluster, prefixed names prevent collisions and make it clear which environment a resource belongs to. But it changes the DNS names, which means the package's generated manifests are environment-aware.

Alternative: keep instance names unprefixed, rely solely on namespace isolation. Since namespaces are prefixed (`dev-backend` vs `prod-backend`), the DNS names are already unique: `api.dev-backend.svc.cluster.local` vs `api.prod-backend.svc.cluster.local`. The instance name in the outer fixpoint would need some other disambiguation strategy (compound key? `"dev/api"`?).

This needs a decision. My lean: prefix instance names. It's simple, it avoids a new key-format concept, and the resulting K8s resource names are unambiguous. The tradeoff (different DNS name from a single-env deploy) is acceptable because the package uses `scope.instanceName` and `fqdn` refs, not hardcoded strings.

### 9.2 `recursiveUpdate` vs Shallow Merge

`recursiveUpdate` merges deeply, which can accidentally merge things you wanted to replace. Example:

```nix
base = { postgres = { backup = { enabled = false; schedule = "never"; }; }; };
over = { postgres = { backup = { enabled = true; }; }; };
recursiveUpdate base over
# → { postgres = { backup = { enabled = true; schedule = "never"; }; }; }
# Surprise: schedule = "never" survived
```

For service config overrides, shallow merge per service (`base.postgres // over.postgres`) is safer:

```nix
base.postgres // over.postgres
# → { backup = { enabled = true; }; }
# schedule is gone -- which is what you'd expect from "I'm overriding backup config"
```

But this loses non-overridden fields from the service. You need:

```nix
base.postgres // { backup = base.postgres.backup // { enabled = true; }; }
```

Which is verbose. The `withOverrides` helper from section 4.7 handles the common case (shallow merge per service), and for deeper merges you compose explicitly.

### 9.3 Fragment vs Pre-Merged Composition

The document shows two composition styles:

1. **Pre-merged**: teams merge their services before passing to `mkCluster` (`backend.services // frontend.services`)
2. **Fragments**: teams pass structured fragments, `mkCluster` merges with collision detection

Fragments are safer but add a concept. Pre-merged is simpler but silent on collisions. For teams that coordinate closely (small org, shared repo), pre-merged works. For larger orgs where teams work independently, fragments with collision detection are worth the extra concept.

### 9.4 Auto-Install Interaction

In a multi-deploy scenario with `autoInstall = true`:

- `dev-api` needs `postgres` -- auto-install creates one. Where? In `dev-data`?
- `prod-api` also needs `postgres` -- auto-install creates another in `prod-data`?

The auto-install system (doc 05) needs to respect `_envScope`. An auto-installed package should be scoped to the requesting environment, using the package's `defaultNamespace` prefixed with the environment name.

### 9.5 When to Use Multi-Deploy vs Multi-Cluster

Multi-deploy (same cluster, different namespaces) works for:
- Dev/staging environments that share infrastructure
- Preview environments per PR
- Cost savings (one cluster, multiple tenants)

Separate cluster definitions work for:
- Prod isolation (separate cluster, separate blast radius)
- Different cloud regions
- Compliance boundaries

The DX should support both with the same building blocks. The env override files (`envs/dev.nix`, `envs/prod.nix`) work in both cases -- they don't know whether they're being used for multi-deploy or multi-cluster.

---

## 10. Summary of the DX

What a team writes:

| Task | Mechanism | Ceremony |
|---|---|---|
| Define services | `ns "backend" { api = { ... }; }` | None -- it's an attrset |
| Configure a package | `api = { replicas = 3; image = "..."; }` | None -- config fields |
| Select a package | `cache = { package = "valkey"; }` | One field |
| Alias for discovery | `aliases = [ "sessionStore" ]` | One field |
| Custom inline package | `package = myFn;` | Write a Nix function |
| Assign namespace | `inNamespace "backend" { ... }` | One helper call |
| Multi-deploy | `prefixEnv "dev" base // prefixEnv "prod" base` | One helper + merge |
| Env-specific overrides | `withOverrides base envCfg.serviceOverrides` | Import a file |
| Compose teams | `backend.services // frontend.services` or fragments | Merge or list |
| Namespace policies | `namespaces.data.networkPolicies.my-policy = { ... }` | Named attrsets |
| Cross-team namespace sharing | Both teams write to same namespace attr | Just merge |
| Cluster-wide package defaults | `packageDefaults.postgres = { ... }` | One field in mkCluster |
| Override inner resources | `overrideParts = self: super: { ... }` | Escape hatch |

What the system does automatically:
- Dependency resolution (DNS-like, namespace-first)
- Reachability checking (NetworkPolicy validation)
- Deploy ordering (topological sort on DAG)
- Namespace resource creation
- Environment-scoped resolution (multi-deploy)
- Collision detection (fragments mode)
