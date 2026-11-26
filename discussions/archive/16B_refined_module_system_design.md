# Module System: Refined Design

## Working Document — March 2026

**Status:** Design refinement — incorporates operator feedback on doc 16
**Predecessors:** docs 11–16

---

## Core Philosophy Recap

kix has two systems that serve different purposes. Mixing them up leads to
bad design.

**Configuration (module options):** Values that control behavior — feature
flags, metadata, aggregation, policy. Things that don't reference other
instances.

**Wiring (DI):** References to other cluster resources. Which TLS issuer,
which storage class, which cache. These are dependencies between instances —
the DI system resolves them automatically and tracks them via string context.

**Rule of thumb:** If it references another instance, it's wiring (DI). If
it's a value that controls behavior, it's configuration (module option).
Config options that are secretly dependency names are a design smell.

---

## DI Philosophy: The Nixpkgs Model

### Packages Declare Concrete Dependencies, Not Abstract Interfaces

A kix package declares the concrete things it was built and tested with:

```nix
# packages/python-app/default.nix
{
  scope, config, lib,
  postgres ? null,
  valkey ? null,
  cluster-issuer ? null,
  ingress-nginx ? null,
}:
```

This says: "I was made to work with postgres, valkey, a cluster-issuer, and
ingress-nginx. If you provide them, I'll use them. If not, I'll degrade
gracefully (they default to null)."

The package does **not** say "give me any database" or "give me any cache."
It says `postgres` and `valkey` — the concrete things the package author
tested against. This mirrors how nixpkgs works: a package depends on `gcc`,
not on "a compiler." It might also work with `clang`, but the package author
doesn't promise that.

### Why Not Abstract Interfaces?

It's tempting to introduce a formal interface system — `implements =
[ "cache" ]` on valkey, then packages depend on `cache ? null`. But this
creates problems:

1. **Who defines the interfaces?** You need a registry of interface names
   and their required `.out` fields. This is governance overhead that grows
   with every new package type.

2. **False compatibility.** Just because two things implement `cache`
   doesn't mean they're interchangeable. Redis has Lua scripting, Valkey
   doesn't support all Redis modules, Memcached has totally different
   semantics. An interface says "structurally compatible" but the app needs
   "behaviorally compatible."

3. **Over-restriction on package authors.** If the interface says `cache`
   must expose `.out.fqdn` and `.out.port`, but a new cache also exposes
   `.out.clusterMode`, the package can't use it without updating the
   interface. The interface becomes a bottleneck.

4. **The nixpkgs lesson.** Nixpkgs has been wildly successful without
   abstract dependency interfaces. A package says `gcc`, you can `.override
   { gcc = clang; }` if you want. The override is the escape hatch, not a
   type system.

### What Gets Verified Instead

kix uses **structural verification**: when a package accesses
`postgres.out.fqdn`, the evaluation fails if the injected instance doesn't
expose `.out.fqdn`. This is duck typing — if it quacks like a postgres
(exposes the same outputs), it works.

This catches real errors (passing a storage-class where a database was
expected) without the overhead of a formal type system.

### Who Decides Substitutions?

The **cluster operator** decides. Not the package author.

The package author says: "I built this with `valkey`." The cluster operator
can substitute:

```nix
# Approach 1: Aliases — make valkey resolve everywhere redis is requested
valkey-session = {
  package = packages.valkey;
  packageType = "valkey";
  aliases = [ "redis" ];  # any package asking for "redis" gets this valkey
};

# Approach 2: Explicit deps override — per-instance, like nixpkgs .override
shopfront-prod = {
  package = packages.python-app;
  deps = {
    redis = config.instances.data.valkey-session;
  };
};
```

This puts the substitution decision where it belongs: with the person who
knows the cluster topology and can test whether the substitution actually
works. The package maintainer says "I made it work with redis." The cluster
operator says "I know valkey is compatible here, use it."

If the substitution is wrong (e.g. passing a postgres for redis), the
structural check catches it when the package tries to access outputs that
don't exist. No formal interface needed.

---

## Strict Separation: Config vs Deps

A recurring source of boilerplate is config options that shadow DI
dependencies. For example:

```nix
# BAD: config option that duplicates a DI concern
effectiveStorageClass =
  if cfg.storage.storageClass != null then cfg.storage.storageClass
  else if storage-class != null then storage-class.out.defaultClass
  else null;
```

Every package repeats this dance: check config, fall back to DI, handle
null. This is error-prone and violates the separation principle.

**The rule: if it's a reference to another instance, it goes in `deps`,
never in `config`.**

```nix
# GOOD: cluster operator overrides DI directly
shopfront-postgres = {
  package = packages.stackgres-cluster;
  packageType = "postgres";
  config = {
    instances = 3;
    storage.size = "400Gi";
    # No storageClass config option — that's wiring
  };
  # Need a specific storage class? Override the DI.
  deps = {
    storage-class = ref.kube-system.localzfs-retain;
  };
};
```

Inside the package, the code is simple:

```nix
{ scope, config, lib, storage-class ? null }:
let
  cfg = config;
in self: {
  pvc = scope.mkResource {
    kind = "PersistentVolumeClaim";
    spec = {
      storageClassName = if storage-class != null
        then storage-class.out.defaultClass
        else null;
      resources.requests.storage = cfg.storage.size;
    };
  };
}
```

One source of truth. No config-vs-DI priority dance. The `deps` override
is the escape hatch, and it's the cluster operator's decision.

---

## DI Objects as Rich Resources

Infrastructure instances should expose not just data but **transformer
functions** through their `out` attribute. This fits the DSL principle that
"resources are rich objects."

### Example: cluster-issuer.withCert

Instead of every package manually adding TLS annotations:

```nix
# Repetitive boilerplate in every package with an Ingress:
annotations = lib.optionalAttrs (cluster-issuer != null) {
  "cert-manager.io/cluster-issuer" = cluster-issuer.out.name;
};
```

The cluster-issuer package exposes a transformer:

```nix
# packages/cluster-issuers/default.nix
{ scope, config, lib }:
self: {
  out = {
    name = config.mainIssuer;
    # Transformer: add TLS annotation to any resource
    withCert = resource: resource // {
      metadata = (resource.metadata or {}) // {
        annotations = (resource.metadata.annotations or {}) // {
          "cert-manager.io/cluster-issuer" = self.out.name;
        };
      };
    };
  };
}
```

Consuming packages use the pipe operator:

```nix
{ scope, config, lib, cluster-issuer ? null }:
let cfg = config; in
self: {
  ingress = if cfg.ingress.enabled then
    scope.mkResource {
      kind = "Ingress";
      spec.ingressClassName = cfg.ingress.className;
      spec.rules = map (h: { host = h.host; http.paths = h.paths; }) cfg.ingress.hosts;
    }
    |> (if cluster-issuer != null then cluster-issuer.out.withCert else lib.id)
  else null;
}
```

The DI-ed object provides the operation. The package doesn't need to know
how cert-manager annotations work — it just pipes through `withCert`. If
there's no cluster-issuer, the pipe is identity. Clean.

Other examples of transformers that infrastructure packages could expose:

- `storage-class.out.withStorageClass` — add storageClassName to a PVC
- `ingress-nginx.out.withIngressClass` — set ingressClassName on an Ingress
- `kube-prometheus-stack.out.withServiceMonitor` — wrap a service with monitoring

These are optional conveniences. Packages can still access `.out.name` or
`.out.defaultClass` directly when the transformer pattern doesn't fit.

---

## Module System: Cross-Cutting Aggregation

The module system's strength is aggregating metadata across team-owned
fragments. This is pure configuration — values, not references.

### Tenants and Network Policies

Teams declare their tenant membership. The platform aggregates it.

```nix
# fragments/nw1/networking.nix — platform module
{ packages, ... }: { config, lib, ... }: {

  options.tenants = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options.namespaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
      };
    });
    default = {};
  };

  config.instances.kube-system.network-policies = {
    package = packages.network-policies;
    config = {
      dnsAppLabel = "coredns";
      tenants = lib.mapAttrs (_: t: {
        namespaces = t.namespaces;
      }) config.tenants;
    };
  };
}

# fragments/nw1/shopfront.nix — team declares membership
{ ... }: { config, ... }: {
  config.tenants.acme.namespaces = [
    "shopfront-prod" "shopfront-stage" "shopfront-demo"
  ];
}

# fragments/nw1/ledgerly.nix — another team
{ ... }: { config, ... }: {
  config.tenants.tidewater.namespaces = [ "ledgerly-prod" ];
}
```

The network-policies package receives the merged tenant config. No manual
coordination between teams.

**Future direction:** The DI dependency graph already knows that python-app
depends on postgres. Fine-grained network policies (per-service, per-port)
could be derived from this graph automatically. This is a natural extension
once the DI system is stable, but not a near-term design goal.

### Priority Classes

Priority values are metadata, not references — pure configuration:

```nix
# fragments/nw1/networking.nix — platform declares the option
{ packages, ... }: { config, lib, ... }: {

  options.priorities = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        value = lib.mkOption { type = lib.types.int; };
        description = lib.mkOption { type = lib.types.str; default = ""; };
      };
    });
    default = {};
  };

  config.instances.kube-system.priority-classes = {
    package = packages.priority-classes;
    config.classes = config.priorities;
  };
}

# fragments/nw1/shopfront.nix — team declares their priorities
{ ... }: { config, ... }: {
  config.priorities = {
    shopfront-prod = { value = 1000; };
    shopfront-stage = { value = 500; };
  };
}
```

**Open question:** How priority classes get attached to workloads. Today
it's `priorityClassName = "shopfront-prod"` — a string. This could become a
DI reference to a priority-class resource, making the dependency tracked.
Worth exploring but not blocking.

### Monitoring as a Conditional Feature

Monitoring is a feature flag (configuration) that conditionally creates
instances (which are then available for DI):

```nix
# fragments/nw1/monitoring.nix
{ packages, kix, ... }: { config, lib, ... }: {

  options.monitoring = {
    enabled = lib.mkEnableOption "cluster-wide Prometheus monitoring";
    scrapeInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
    };
  };

  config = lib.mkIf config.monitoring.enabled {
    instances.monitoring-system = {
      kube-prometheus-stack = {
        package = kix.fromHelmChart { /* ... */ };
        packageType = "kube-prometheus-stack";
      };
      loki = { package = kix.fromHelmChart { /* ... */ }; };
      promtail = { package = kix.fromHelmChart { /* ... */ }; };
    };
  };
}
```

Packages that want to create ServiceMonitors declare a DI dependency on
the monitoring stack:

```nix
# packages/valkey/default.nix
{ scope, config, lib, kube-prometheus-stack ? null }:
let
  hasMonitoring = kube-prometheus-stack != null;
in self: {
  serviceMonitor = if hasMonitoring
    then scope.mkResource { kind = "ServiceMonitor"; /* ... */ }
    else null;
}
```

If monitoring is enabled → instance exists → DI resolves it → ServiceMonitor
is created. If disabled → no instance → DI returns null → no ServiceMonitor.
The module flag controls existence; DI handles the wiring. No
`scope.clusterConfig` needed.

---

## DNS Rewrites: Aggregation from Instance Metadata

A practical duplication problem: hostnames appear in both the Ingress
resource (package config) and the CoreDNS rewrite list (infra config).
Adding a hostname to an app means updating two places.

The module system can eliminate this via aggregation:

```nix
# fragments/nw1/infra.nix — platform declares the option
{ packages, ... }: { config, lib, ... }: {

  options.dnsRewrites = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        hostname = lib.mkOption { type = lib.types.str; };
        target = lib.mkOption {
          type = lib.types.enum [ "private" "public" ];
          default = "private";
        };
      };
    });
    default = [];
  };

  config.instances.kube-system.coredns = {
    package = packages.coredns;
    config.dnsRewrites = config.dnsRewrites;
  };
}
```

Teams register their hostnames alongside their Ingress config:

```nix
# fragments/nw1/shopfront.nix
{ ... }: { config, ... }: {
  config.dnsRewrites = [
    { hostname = "admin.packwise.example"; target = "public"; }
    { hostname = "packwise.example"; target = "public"; }
  ];

  config.instances.shopfront-prod.shopfront-prod-general = {
    package = packages.python-app;
    config.ingress = {
      enabled = true;
      hosts = [
        { host = "admin.packwise.example"; paths = [{ path = "/"; service = "backend"; }]; }
        { host = "packwise.example"; paths = [{ path = "/"; service = "backend"; }]; }
      ];
    };
  };
}
```

This still has some duplication (hostnames appear in both `dnsRewrites` and
`ingress.hosts`). A future refinement could derive DNS entries automatically
from Ingress resources in the evaluation phase — the information is already
there. But the explicit aggregation is a solid first step that's simple to
implement and understand.

---

## Package-Level Typed Options

Packages can optionally declare typed config schemas:

```nix
# packages/valkey/_kixOptions.nix
{ lib, ... }: {
  options = {
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 3;
      check = x: x >= 0;  # no negative replicas
    };
    sentinel.enabled = lib.mkEnableOption "sentinel mode";
    sentinel.quorum = lib.mkOption { type = lib.types.int; default = 2; };
    auth.enabled = lib.mkOption { type = lib.types.bool; default = true; };
    metrics.enabled = lib.mkOption { type = lib.types.bool; default = false; };
    persistence.enabled = lib.mkOption { type = lib.types.bool; default = false; };
    persistence.size = lib.mkOption { type = lib.types.str; default = "8Gi"; };
  };
}
```

`config.replicaCount = "three"` becomes a type error caught at evaluation
time instead of a silent bug discovered at deploy time. The `check` function
on options provides validation beyond type checking.

These options are always **configuration** — values that control behavior.
Infrastructure references (storage class, monitoring) are always DI.

---

## Cluster Composition

The cluster operator composes modules:

```nix
# clusters/nw1.nix
{ kix, packages }:

kix.buildCluster {
  name = "nw1";
  clusterLabels = {
    "app.kubernetes.io/part-of" = "nw1";
    cluster = "nw1-prod";
    team = "platform";
  };
  modules = [
    # Platform infra (Luca owns)
    (import ../fragments/nw1/infra.nix { inherit packages kix; })
    (import ../fragments/nw1/monitoring.nix { inherit packages kix; })
    (import ../fragments/nw1/networking.nix { inherit packages; })

    # Application teams (each team owns their fragment)
    (import ../fragments/nw1/shopfront.nix { inherit packages; })
    (import ../fragments/nw1/ledgerly.nix { inherit packages; })
    (import ../fragments/nw1/n8n.nix { inherit packages; })
    (import ../fragments/nw1/metabase.nix { inherit packages; })
  ];
}
```

The monolithic 2200-line cluster file becomes ~8 focused modules. Each team
owns their fragment. The cluster operator owns the composition and infra.

### Conflict Resolution

| Scenario | What Happens |
|----------|-------------|
| Two teams define same `(ns, instance)` | Module system merge error |
| Team and platform both set `replicaCount` | `mkDefault` (platform) loses to normal priority (team) |
| Platform forces a policy | `mkForce` wins over team settings |
| Two teams add namespaces to same tenant | Lists merge (both preserved) |
| Ambiguous DI (two instances match, no explicit override) | DI resolution error: "ambiguous, specify explicitly" |
| No cluster-issuer in cluster | DI returns null, package degrades gracefully |

---

## Complete Example: Application Team Fragment

A team fragment with no infrastructure concerns — all wiring is DI:

```nix
# fragments/nw1/shopfront.nix
{ packages, ... }:
let
  mkSgBackup = { bucket, credentialsSecret }: { /* ... */ };
  shopfrontExtensions = [ "pgcrypto" "citext" "pg_trgm" ];

  mkShopfrontEnv = envName: envConfig: { lib, config, ... }: {
    config.instances.${envName} = {
      "${envName}-general" = {
        package = packages.python-app;
        packageType = "python-app";
        config = {
          appName = "shopfront";
          environment = envConfig.environment;
          backend.image = {
            repository = "ghcr.io/northwind/shopfront/web";
            tag = envConfig.imageTag;
          };
          backend.replicaCount = envConfig.replicas;
          ingress = {
            enabled = true;
            # No clusterIssuer — DI wires it
            # No className — DI wires it
            hosts = envConfig.hosts;
          };
        };
      };

      postgres = {
        package = packages.stackgres-cluster;
        packageType = "postgres";
        config = {
          instances = envConfig.pgInstances;
          postgres.version = "16";
          postgres.extensions = shopfrontExtensions;
          storage.size = envConfig.pgStorage;
          # No storageClass — DI wires it
          backup = mkSgBackup envConfig.backup;
        };
      };

      "valkey-${envName}" = {
        package = packages.valkey;
        packageType = "valkey";
        config = {
          replicaCount = envConfig.valkeyReplicas;
          sentinel.enabled = true;
          metrics.enabled = true;
          persistence = { enabled = true; size = "20Gi"; };
        };
      };
    };

    config.tenants.acme.namespaces = [ envName ];
    config.priorities.${envName} = { value = envConfig.priority; };
  };
in
{ config, lib, ... }: {
  imports = [
    (mkShopfrontEnv "shopfront-prod" {
      environment = "production";
      imageTag = "v26.12.4";
      replicas = 16;
      pgInstances = 3;
      pgStorage = "400Gi";
      valkeyReplicas = 3;
      priority = 1000;
      backup = {
        bucket = "northwind-stackgres-prod-shopfront";
        credentialsSecret = "stackgres-storage-creds-shopfront";
      };
      hosts = [
        { host = "admin.packwise.example"; paths = [{ path = "/"; service = "backend"; }]; }
        { host = "packwise.example"; paths = [{ path = "/"; service = "backend"; }]; }
      ];
    })
    (mkShopfrontEnv "shopfront-stage" {
      environment = "staging";
      imageTag = "v26.12.5-rc1";
      replicas = 4;
      pgInstances = 2;
      pgStorage = "100Gi";
      valkeyReplicas = 1;
      priority = 500;
      backup = {
        bucket = "northwind-stackgres-stage-shopfront";
        credentialsSecret = "stackgres-storage-creds-shopfront";
      };
      hosts = [
        { host = "staging.packwise.example"; paths = [{ path = "/"; service = "backend"; }]; }
      ];
    })
  ];
}
```

**What this fragment does NOT contain:**
- Issuer names (`"northwind"`)
- Ingress class names (`"public"`)
- Storage class names (`"localzfs-retain"`)
- Monitoring configuration
- Network policy details

All of those are handled by the platform modules + DI. The team focuses on
what they own: image tags, replica counts, hostnames, database sizing.

### Overriding DI When Needed

If staging needs a private ingress controller instead of the default:

```nix
(mkShopfrontEnv "shopfront-stage" {
  # ... same as above ...
}) // {
  # Override just the DI for this environment's python-app
  config.instances.shopfront-stage."shopfront-stage-general".deps = {
    ingress-nginx = ref.nginx-system.ingress-private-v2;
  };
}
```

`deps` is the explicit escape hatch. It's separate from `config` — wiring
is never mixed with behavior. Like nixpkgs `.override { }`, it's the
consumer's choice.

---

## What Goes Where — Summary

```
Configuration (module options)            Wiring (DI)
──────────────────────────────            ────────────
monitoring.enabled = true                 cluster-issuer → cluster-issuers instance
tenants.acme.namespaces = [...]      ingress-nginx → ingress controller instance
priorities.shopfront-prod.value = 1000      storage-class → storage-classes instance
dnsRewrites = [...]                       postgres → postgres instance
instance config: replicas, images, ...    valkey → valkey instance
                                          kube-prometheus-stack → monitoring instance
```

## What the Module System IS For

1. **Splitting a monolithic cluster file** into team-owned fragments
2. **Aggregating metadata** across fragments (tenants, priorities, DNS rewrites)
3. **Feature flags** that conditionally create instances (monitoring.enabled)
4. **Configuration values** for instances (replicas, images, env vars)
5. **Policy enforcement** via mkForce (platform overrides team settings)
6. **Typed config validation** via package-level option schemas

## What the Module System is NOT For

1. **Wiring instances together** — that's DI
2. **Referencing instance outputs** — that's DI + string context
3. **Config options that are really dependency names** — use DI args + `deps` overrides
4. **Abstract dependency interfaces** — packages declare concrete deps, cluster operators substitute via aliases / deps overrides
