# Module System: Personas, Use Cases, and Real Examples

## Working Document — March 2026

**Status:** Design exploration — concrete scenarios from nw1 cluster
**Predecessors:** docs 12–15 (module system approaches), doc 11 (infrastructure DI)

---

All examples below are based on the real nw1 cluster (19 namespaces, ~26
instances, Hetzner). The "before" is today's `clusters/nw1.nix`. The "after"
shows what it would look like with the module system.

---

## Fundamental Distinction: Configuration vs Wiring

The module system and the DI system serve different purposes. Mixing them up
leads to bad design.

**Configuration (module options):** Values that control behavior. Feature flags,
metadata, aggregation, policy. Things that don't reference other instances.

- `monitoring.enabled = true`
- `tenants.acme.namespaces = [ "shopfront-prod" ... ]`
- `priorities.shopfront-prod.value = 1000`
- Instance config: replica counts, image tags, resource limits, env vars

**Wiring (DI):** References to other cluster resources. Which TLS issuer,
which storage class, which ingress controller. These are dependencies between
instances — the DI system resolves them automatically and tracks them via
string context.

- python-app needs an issuer → `{ ..., cluster-issuer ? null }:` in package args
- postgres needs a storage class → `{ ..., storage-class ? null }:` in package args
- coredns needs ingress FQDNs → `{ ..., ingress-nginx ? null }:` in package args

**Rule of thumb:** If it references another instance, it's wiring (DI). If it's
a value that controls behavior, it's configuration (module option).

---

## Persona 1: Cluster Operator (Luca)

**Responsibility:** Owns the cluster definition, stitches modules together,
sets cluster-wide policies. The person who runs `nix build .#cluster-nw1`.

### Use Case 1A: Composing a Cluster from Modules

**Today** — one giant 2200-line `nw1.nix` file. Everything in one place: infra,
apps, environments. Only Luca can safely edit it.

**After** — Luca composes modules:

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

**What changed:** The 2200-line file is split into ~8 focused modules. Each
team owns their fragment. Luca owns the cluster composition + infra.

### Use Case 1B: ref and DI for DNS Rewrites

Today, CoreDNS uses `ref.nginx-system.ingress-private-v2.out.fqdn` for DNS
rewrites. This is a dependency on another instance's output — it's **wiring**.

**After** — CoreDNS declares DI dependencies on the ingress instances:

```nix
# packages/coredns/default.nix
{
  scope, config, lib,
  ingress-private ? null,   # resolved via DI to ingress-private-v2
  ingress-public ? null,    # resolved via DI to ingress-public-v2
}:
```

The DNS rewrite hostnames are **configuration** (which hostnames to rewrite is
a value, not a dependency). So those are declared via module option or instance
config:

```nix
# fragments/nw1/infra.nix
config.instances.kube-system.coredns = {
  package = packages.coredns;
  config = {
    replicaCount = 3;
    dnsRewrites = [
      # The hostnames are config; the target instances are resolved via DI
      # The coredns package uses ingress-private.out.fqdn for "private" targets
      { hostname = "registry.nw1.example.net"; target = "private"; }
      { hostname = "prometheus.nw1.example.net"; target = "private"; }
      { hostname = "grafana.nw1.example.net"; target = "private"; }
      { hostname = "console.s3.nw1.example.net"; target = "public"; }
    ];
  };
};
```

Inside the coredns package:

```nix
# packages/coredns/default.nix
{ scope, config, lib, ingress-private ? null, ingress-public ? null }:
let
  cfg = config;  # module system already merged defaults + user config
  targets = {
    "private" = ingress-private;
    "public" = ingress-public;
  };
  rewritePlugins = map (rw:
    let tgt = targets.${rw.target}; in
    { name = "rewrite";
      parameters = "name exact ${rw.hostname} ${tgt.out.fqdn} answer auto"; }
  ) cfg.dnsRewrites;
in
self: { ... }
```

The dependency on ingress instances is tracked via DI (string context). The
hostname list is pure configuration. Clean separation.

---

## Persona 2: Platform Engineer / SRE

**Responsibility:** Manages monitoring, backup, operators, security, networking
policies. Sets standards that application teams must follow.

### Use Case 2A: Monitoring as a Cross-Cutting Concern

**Today** — Monitoring is an instance in `monitoring-system` namespace.
Application teams manually set `prometheus.service.enabled = true` in their
package config. There's no enforcement — a team can forget it.

**After** — Platform declares a monitoring option as **configuration** (feature
flag). The monitoring stack itself is an instance wired via DI:

```nix
# fragments/nw1/monitoring.nix
{ packages, kix, ... }: { config, lib, ... }: {

  # Declare the capability — this is configuration (feature flag)
  options.monitoring = {
    enabled = lib.mkEnableOption "cluster-wide Prometheus monitoring";
    scrapeInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
    };
  };

  config = lib.mkIf config.monitoring.enabled {
    # Provide the monitoring stack as instances
    instances.monitoring-system = {
      kube-prometheus-stack = {
        package = kix.fromHelmChart { /* ... */ };
        packageType = "kube-prometheus-stack";
        config.values.grafana."grafana.ini".server.root_url =
          "https://grafana.nw1.example.net";
      };
      loki = { package = kix.fromHelmChart { /* ... */ }; packageType = "loki"; };
      promtail = { package = kix.fromHelmChart { /* ... */ }; packageType = "promtail"; };
    };
  };
}
```

Application teams enable it:

```nix
config.monitoring.enabled = true;
```

Packages that want to create ServiceMonitors declare a DI dependency on the
monitoring stack — they don't read a config option:

```nix
# packages/valkey/default.nix — wiring, not config
{ scope, config, lib, kube-prometheus-stack ? null }:
let
  hasMonitoring = kube-prometheus-stack != null;
in
self: {
  serviceMonitor = if hasMonitoring then scope.mkResource { ... } else null;
}
```

If monitoring is enabled → the kube-prometheus-stack instance exists → DI
resolves it → the package creates the ServiceMonitor. If monitoring is
disabled → no instance → DI returns null → no ServiceMonitor. No
`scope.clusterConfig` needed.

### Use Case 2B: Network Policies Derived from Module Config

**Today** — The `network-policies` package has a hardcoded config with tenant
namespace lists. Every time a namespace is added, Luca must update it manually.

**After** — Teams declare their tenant membership. This is **configuration**
(metadata aggregation, no instance references):

```nix
# fragments/nw1/networking.nix
{ packages, ... }: { config, lib, ... }: {

  # Declare tenant option — any module can add namespaces to a tenant
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
      # Derive tenant config from the module tree
      tenants = lib.mapAttrs (_: t: {
        namespaces = t.namespaces;
      }) config.tenants;
    };
  };
}

# fragments/nw1/shopfront.nix — team declares their tenant
{ ... }: { config, lib, ... }: {
  config.tenants.acme.namespaces = [
    "shopfront-prod"
    "shopfront-stage"
    "shopfront-demo"
  ];
  # ... instance definitions ...
}

# fragments/nw1/ledgerly.nix — another team
{ ... }: { config, lib, ... }: {
  config.tenants.tidewater.namespaces = [ "ledgerly-prod" ];
  # ... instance definitions ...
}
```

**What changed:** Namespace-to-tenant mapping is declared by the team that
owns the namespace, not centrally hardcoded. The network-policies module
aggregates automatically.

### Use Case 2C: TLS Issuers as DI-Resolved Infrastructure

**Today** — Every ingress hardcodes `clusterIssuer = "northwind"`. If the issuer
name changes, 8+ places must be updated.

**This is wiring, not configuration.** The python-app package depends on a
cluster-issuer. The DI system should resolve it.

```nix
# packages/python-app/default.nix
{
  scope, config, lib,
  postgres ? null,
  valkey ? null,
  cluster-issuer ? null,  # ← DI resolves this to the cluster-issuers instance
}:
let
  cfg = config;
in
self: {
  ingress = if cfg.ingress.enabled then
    scope.mkResource {
      kind = "Ingress";
      annotations = lib.optionalAttrs (cluster-issuer != null) {
        "cert-manager.io/cluster-issuer" = cluster-issuer.out.name;
      };
      spec.ingressClassName = cfg.ingress.className;
      # ...
    }
  else null;
}
```

The cluster-issuers instance exposes the issuer name via `out.name`. The
dependency is tracked via string context — automatic, no hardcoded strings.

The module just declares the cluster-issuers instance:

```nix
# fragments/nw1/infra.nix
config.instances.cert-manager.cluster-issuers = {
  package = packages.cluster-issuers;
  packageType = "cluster-issuer";  # DI resolves "cluster-issuer" to this
  config = {
    mainIssuer = "northwind";
    issuers = {
      northwind = { server = "..."; email = "..."; dnsZones = [ "shopfront.example" ... ]; };
      letsencrypt-production = { server = "..."; email = "..."; };
    };
  };
};
```

No `config.tls.defaultIssuer` module option. The issuer config lives in the
cluster-issuers instance config (where it belongs). The wiring is DI.

### Use Case 2D: Storage Classes as DI-Resolved Infrastructure

**Today** — `storageClass = "localzfs-retain"` hardcoded in 6+ places.

**This is wiring, not configuration.** Packages that need storage should
declare a DI dependency on a storage provider:

```nix
# packages/stackgres-cluster/default.nix
{
  scope, config, lib,
  storage-class ? null,  # ← DI resolves to the storage-classes instance
}:
let
  cfg = config;
  # Storage class from DI, overridable via config
  effectiveStorageClass =
    if cfg.storage.storageClass != null then cfg.storage.storageClass
    else if storage-class != null then storage-class.out.defaultClass
    else null;
in
# ...
```

If a package needs a specific named class (not the default), it can still
set `config.storage.storageClass = "localzfs-retain"` explicitly. But the
default wiring happens via DI.

### Use Case 2E: Priority Classes Derived from Module Config

**Today** — Priority classes are manually listed and must be kept in sync.

This IS genuinely **configuration** — priority values are metadata, not
references to other instances:

```nix
# fragments/nw1/networking.nix (or a separate platform module)
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

  # Platform aggregates into the priority-classes package
  config.instances.kube-system.priority-classes = {
    package = packages.priority-classes;
    config.classes = config.priorities;
  };
}

# fragments/nw1/shopfront.nix — team declares their priorities
config.priorities = {
  shopfront-prod = { value = 1000; };
  shopfront-stage = { value = 500; };
  shopfront-demo = { value = 500; };
};

# fragments/nw1/ledgerly.nix — another team
config.priorities.ledgerly-prod = { value = 1000; };
```

---

## Persona 3: Service Maintainer (Package Author)

**Responsibility:** Maintains a kix package (e.g., python-app, valkey,
stackgres-cluster). Defines what the package needs (DI dependencies), what
config options control its behavior, and what resources it produces.

### Use Case 3A: Package Declares Infrastructure Dependencies via DI

The key insight: infrastructure references (issuers, storage classes, ingress
controllers) are **dependencies**, just like postgres and valkey. Packages
advertise them the same way:

```nix
# packages/python-app/default.nix
{
  scope, config, lib,
  postgres ? null,           # data dependency — resolved via DI
  valkey ? null,             # data dependency — resolved via DI
  cluster-issuer ? null,     # infra dependency — resolved via DI
  ingress-nginx ? null,      # infra dependency — resolved via DI
}:
let
  cfg = config;  # module system already merged defaults + user config
in
self: {
  configmap = scope.mkResource {
    kind = "ConfigMap";
    data = {}
      // lib.optionalAttrs (postgres != null) {
        DATABASE_HOST = postgres.out.fqdn;  # wiring via DI
      }
      // lib.optionalAttrs (valkey != null) {
        VALKEY_HOST = valkey.out.fqdn;      # wiring via DI
      };
  };

  ingress = if cfg.ingress.enabled then
    scope.mkResource {
      kind = "Ingress";
      annotations = lib.optionalAttrs (cluster-issuer != null) {
        "cert-manager.io/cluster-issuer" = cluster-issuer.out.name;
      };
      # ingress class name could also come from DI:
      spec.ingressClassName =
        if ingress-nginx != null
        then ingress-nginx.out.ingressClassName
        else cfg.ingress.className;
    }
  else null;
}
```

No hardcoded issuer names. No hardcoded ingress class names. The DI system
resolves them. The dependency graph tracks them automatically.

### Use Case 3B: Package Exposes Typed Options (Optional)

If the valkey maintainer wants typed config validation:

```nix
# packages/valkey/_kixOptions.nix
{ lib, ... }: {
  options = {
    replicaCount = lib.mkOption { type = lib.types.int; default = 3; };
    sentinel.enabled = lib.mkEnableOption "sentinel mode";
    sentinel.quorum = lib.mkOption { type = lib.types.int; default = 2; };
    auth.enabled = lib.mkOption { type = lib.types.bool; default = true; };
    metrics.enabled = lib.mkOption { type = lib.types.bool; default = false; };
    persistence.enabled = lib.mkOption { type = lib.types.bool; default = false; };
    persistence.size = lib.mkOption { type = lib.types.str; default = "8Gi"; };
  };
}
```

Now setting `config.replicaCount = "three"` is a type error instead of a
silent bug discovered at deploy time.

Note: these are all **configuration** options (values that control behavior).
Infrastructure dependencies (storage class, monitoring stack) are DI, not
options.

---

## Persona 4: Application Developer (Shopfront Team)

**Responsibility:** Deploys their application. Sets image tags, replica counts,
environment variables, ingress hosts. Doesn't touch infra packages.

### Use Case 4A: Team Owns Their Fragment

**Today** — The Shopfront team's config is inside nw1.nix, mixed with platform
infra. They can't edit it without touching the whole cluster definition.

**After** — They own a fragment. Infrastructure wiring happens automatically
via DI — the team never mentions issuer names, storage class names, or
ingress class names:

```nix
# fragments/nw1/shopfront.nix
{ packages, ... }:
let
  mkSgBackup = { bucket, credentialsSecret }: { /* ... */ };
  valkeyRenameCommands = ''
    rename-command FLUSHDB ""
    rename-command FLUSHALL ""
  '';
  shopfrontExtensions = [ /* pgcrypto, citext, pg_trgm */ ];
in
{ config, lib, ... }: {

  # Declare tenant membership — configuration (metadata)
  config.tenants.acme.namespaces = [
    "shopfront-prod" "shopfront-stage" "shopfront-demo"
  ];

  # Declare priority needs — configuration (values)
  config.priorities = {
    shopfront-prod = { value = 1000; };
    shopfront-stage = { value = 500; };
    shopfront-demo = { value = 500; };
  };

  config.instances = {

    # ── shopfront-prod ──────────────────────────────────
    shopfront-prod = {
      shopfront-prod-general = {
        package = packages.python-app;
        packageType = "python-app";
        config = {
          appName = "shopfront";
          environment = "production";
          priorityClassName = "shopfront-prod";
          backend.image = {
            repository = "ghcr.io/northwind/shopfront/web";
            tag = "v26.12.4";
          };
          backend.replicaCount = 16;
          ingress = {
            enabled = true;
            # No clusterIssuer — DI wires it automatically!
            # No className — DI wires it from the ingress-nginx instance!
            hosts = [
              { host = "admin.packwise.example"; paths = [{ path = "/"; service = "backend"; }]; }
              { host = "packwise.example"; paths = [{ path = "/"; service = "backend"; }]; }
            ];
          };
        };
      };

      postgres = {
        package = packages.stackgres-cluster;
        packageType = "postgres";
        config = {
          instances = 3;
          postgres.version = "16";
          postgres.extensions = shopfrontExtensions;
          storage.size = "400Gi";
          # No storageClass — DI wires it from the storage-classes instance!
          backup = mkSgBackup {
            bucket = "northwind-stackgres-prod-shopfront";
            credentialsSecret = "stackgres-storage-creds-shopfront";
          };
        };
      };

      valkey-shopfront-prod = {
        package = packages.valkey;
        packageType = "valkey";
        config = {
          replicaCount = 3;
          sentinel.enabled = true;
          metrics.enabled = true;
          persistence = { enabled = true; size = "20Gi"; };
        };
      };
    };

    # ── shopfront-stage (smaller, same shape) ───────────
    shopfront-stage = {
      # ... similar but with staging image tags, fewer replicas ...
    };

    # ── shopfront-demo ──────────────────────────────────
    shopfront-demo = {
      # ... similar but with demo config ...
    };
  };
}
```

**What changed vs today:**
- No `clusterIssuer = "northwind"` — wired via DI
- No `className = "public"` — wired via DI
- No `storageClass = "localzfs-retain"` — wired via DI
- Team declares tenants + priorities — platform aggregates automatically
- Fragment is independent — team can edit without touching cluster definition

**What changed vs previous version of this doc:**
- All infrastructure references removed from config. They're DI dependencies
  declared in the package function args, not config values set by app teams.

### Use Case 4B: Overriding DI When Needed

Sometimes a team needs a specific ingress controller (not the default). The
`deps` attribute handles this — like nixpkgs `.override { }`:

```nix
# shopfront-stage uses a different ingress controller
shopfront-stage-general = {
  package = packages.python-app;
  packageType = "python-app";
  config = { ... };
  # Explicit DI override — separate from config, like .override { }
  deps = {
    ingress-nginx = ref.nginx-system.ingress-private-v2;
  };
};
```

`deps` is separate from `config` — wiring is never mixed with behavior.
The DI system auto-resolves everything not in `deps`. Only specify `deps`
when you need to override the default resolution.

### Use Case 4C: Reducing Config Duplication Across Environments

The team writes a module generator (similar to today's `mkShopfrontEnv` but
producing modules):

```nix
mkShopfrontModule = envName: envConfig: { lib, config, ... }: {
  config.instances.${envName} = {
    ${envName} = {
      package = packages.python-app;
      packageType = "python-app";
      config = baseShopfrontConfig // envConfig.appOverrides;
    };
    postgres = {
      package = packages.stackgres-cluster;
      packageType = "postgres";
      config = basePostgresConfig // envConfig.pgOverrides;
    };
    # valkey, etc.
  };
  config.tenants.acme.namespaces = [ envName ];
  config.priorities.${envName} = { value = envConfig.priority; };
};
```

Or use `mkDefault` layers — the base module sets shared defaults, per-env
modules override what differs.

---

## Persona 5: Ledgerly Developer (Second Application Team)

**Responsibility:** Deploys Ledgerly. Uses the same platform infra as
Shopfront but has different requirements.

### Use Case 5A: Independent Fragment, Shared Infrastructure via DI

```nix
# fragments/nw1/ledgerly.nix
{ packages, ... }: { config, lib, ... }: {

  config.tenants.tidewater.namespaces = [ "ledgerly-prod" ];
  config.priorities.ledgerly-prod = { value = 1000; };

  config.instances.ledgerly-prod = {
    ledgerly = {
      package = packages.python-app;
      packageType = "python-app";
      config = {
        releaseName = "ledgerly-prod";
        componentName = "web";
        environment = "production";
        priorityClassName = "ledgerly-prod";
        backend.image = {
          repository = "ghcr.io/northwind/ledgerly/web";
          tag = "latest";
        };
        ingress = {
          enabled = true;
          # No clusterIssuer, no className — DI wires them
          hosts = [
            { host = "app.ledgerly.example";
              paths = [{ path = "/"; service = "backend"; }]; }
          ];
        };
      };
    };

    postgres = {
      package = packages.stackgres-cluster;
      packageType = "postgres";
      config = {
        instances = 2;
        postgres.version = "16";
        storage.size = "50Gi";
        # No storageClass — DI wires it
      };
    };

    valkey-ledgerly-prod = {
      package = packages.valkey;
      packageType = "valkey";
      config = {
        replicaCount = 3;
        sentinel.enabled = true;
        metrics.enabled = true;
        persistence = { enabled = true; size = "20Gi"; };
      };
    };
  };
}
```

**Key point:** Ledgerly team never mentions issuers, storage classes, or
ingress controllers. DI wires them from the cluster's infra instances. Both
teams contribute to the same tenant/priority aggregation without coordinating.

---

## Cross-Persona Interactions Summary

### What Goes Where

```
Configuration (module options)            Wiring (DI)
──────────────────────────────            ────────────
monitoring.enabled = true                 cluster-issuer → cluster-issuers instance
tenants.acme.namespaces = [...]      ingress-nginx → ingress controller instance
priorities.shopfront-prod.value = 1000      storage-class → storage-classes instance
instance config: replicas, images, etc.   postgres → postgres instance
                                          valkey → valkey instance
                                          kube-prometheus-stack → monitoring instance
```

### Data Flow

```
   Module System (configuration)          DI System (wiring)
   ─────────────────────────────          ─────────────────────

   Platform declares options               Platform provides infra instances
   ─────────────────────────               ──────────────────────────────
   options.monitoring.enabled         →    instances.monitoring-system.prometheus
   options.tenants                    →    instances.kube-system.network-policies
   options.priorities                 →    instances.kube-system.priority-classes

   Teams set options                       Teams declare instances
   ────────────────                        ──────────────────────
   config.monitoring.enabled = true        instances.shopfront-prod.shopfront = { ... }
   config.tenants.acme = [...]        instances.shopfront-prod.postgres = { ... }
   config.priorities.shopfront-prod = {...}

   Module system aggregates                DI resolves dependencies
   ────────────────────────                ────────────────────────
   priorities → priority-classes config    python-app.cluster-issuer → cluster-issuers
   tenants → network-policies config       python-app.ingress-nginx → ingress-public-v2
   monitoring.enabled → condl instances    stackgres.storage-class → storage-classes
```

### Conflict Resolution

| Scenario | What Happens |
|----------|-------------|
| Two teams define same `(ns, instance)` | Module system merge error (collision detection) |
| Team and platform both set `replicaCount` | `mkDefault` (platform) loses to normal priority (team) |
| Platform forces a policy | `mkForce` wins over team settings |
| Two teams add namespaces to same tenant | Lists merge (both contributions preserved) |
| Ambiguous DI (two ingress controllers, no explicit override) | DI system error: "ambiguous, specify explicitly" |
| No cluster-issuer in cluster | DI returns null, package skips TLS annotation |

---

## What the Module System IS For (Summary)

1. **Splitting a monolithic cluster file** into team-owned fragments
2. **Aggregating metadata** across fragments (tenants, priorities)
3. **Feature flags** that conditionally create instances (monitoring.enabled)
4. **Configuration values** for instances (replicas, images, env vars)
5. **Policy enforcement** via mkForce (platform overrides team settings)

## What the Module System is NOT For

1. **Wiring instances together** — that's DI (cluster-issuer, storage-class, etc.)
2. **Referencing instance outputs** — that's DI + string context tracking
3. **Config options that are really dependency names** — use DI args instead
