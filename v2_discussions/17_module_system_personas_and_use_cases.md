# Module System: Personas, Use Cases, and Real Examples (Revised)

## Working Document — March 2026

**Status:** Design refinement — resolved open questions from doc 16
**Predecessors:** docs 12–16

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
- coredns needs ingress FQDNs → `{ ..., ingress-private ? null }:` in package args

**Rule of thumb:** If it references another instance, it's wiring (DI). If it's
a value that controls behavior, it's configuration (module option).

### DI Philosophy: The Nixpkgs Model

Packages declare **concrete** dependencies — the things the package author built
and tested with. This mirrors nixpkgs: a package depends on `gcc`, not on "a
compiler." It might also work with `clang`, but the package author doesn't
promise that.

```nix
# The package author says: "I built this with valkey and postgres"
{ scope, config, lib, valkey, postgres ? null, cluster-issuer ? null }:
```

The package does NOT say "give me any cache" or "give me any database." It says
`valkey` and `postgres`. Whether a substitute works (redis for valkey, mysql for
postgres) is the **cluster operator's** call — they know their cluster, they can
test whether a substitution holds. The package author just exposes the knobs.

**How substitution works:** The cluster operator has two tools:

- **Aliases:** `valkey = { package = packages.valkey; aliases = [ "redis" ]; };`
  — makes this valkey inject everywhere `redis` is requested too.
- **deps override:** `deps = { valkey = ref.data.my-redis; };` — per-instance
  override, like nixpkgs `.override { }`.

**What gets verified:** Structural duck typing. When a package accesses
`valkey.out.fqdn`, nix evaluation fails if the injected instance doesn't expose
`.out.fqdn`. No formal interface system — if it quacks right, it works. If you
pass a postgres where a valkey was expected and the package accesses
`.out.sentinelPort`, the eval blows up. That's your signal that the substitution
doesn't hold.

**Why not abstract interfaces?** For the same reason nixpkgs doesn't have them.
A `cache` interface would need a registry, would give false confidence about
behavioral compatibility, and would become a governance bottleneck. The package
maintainer says "I made it work with valkey." The cluster operator says "I know
redis is compatible here." The structural check catches the rest.

**Concrete with generic fallback:** A package can name its arg generically while
defaulting to the concrete thing:

```nix
# "I need a cache. I built it with valkey, but if the cluster provides
# something called 'cache', I'll use that instead."
{ scope, config, lib, valkey, cache ? valkey }:
```

DI tries to resolve `cache` first (looking for an instance with packageType or
alias `cache`). If nothing matches, the Nix default kicks in and `cache` falls
back to whatever `valkey` resolved to. The package uses `cache` internally. The
cluster operator can provide a dedicated cache instance or let it fall through
to the valkey.

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

### Use Case 1B: DI for DNS Rewrites, Module Aggregation to Remove Duplication

Today, CoreDNS uses `ref.nginx-system.ingress-private-v2.out.fqdn` for DNS
rewrites. This is a dependency on another instance's output — it's **wiring**.

The DNS rewrite hostnames themselves are **configuration** — but today they're
duplicated: the same hostname appears in both the CoreDNS rewrite list and in
the application's Ingress resource. Adding a new hostname means updating two
places.

**After** — The module system aggregates DNS entries from across fragments, so
each team declares their hostnames once and both CoreDNS and the Ingress consume
them.

The platform declares a `dnsRewrites` module option:

```nix
# fragments/nw1/infra.nix (relevant section)
{ packages, kix, ... }: { config, lib, ... }: {

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
    config = {
      replicaCount = 3;
      # Aggregated from all fragments — no manual list
      dnsRewrites = config.dnsRewrites;
    };
  };
}
```

Application fragments contribute their hostnames:

```nix
# fragments/nw1/shopfront.nix (relevant section)
config.dnsRewrites = [
  { hostname = "admin.packwise.example"; target = "public"; }
  { hostname = "packwise.example"; target = "public"; }
];
```

Inside the coredns package, the ingress instances are DI dependencies — the
hostname list is pure config:

```nix
# packages/coredns/default.nix
{ scope, config, lib, ingress-private, ingress-public ? null }:
let
  cfg = config;
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
hostname list is pure configuration, aggregated from all fragments. Each team
declares their hostnames once — the module system feeds them to both CoreDNS
and (via the same list) to the Ingress resources in the application package.

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
        # Packages can also find this instance via the "monitoring" alias —
        # since ServiceMonitor (monitoring.coreos.com/v1) isn't specific to
        # any particular Prometheus distribution, the generic name is more
        # appropriate for DI resolution.
        aliases = [ "monitoring" ];
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

Packages that want to create ServiceMonitors declare a DI dependency. The arg
name is generic (`monitoring`) since ServiceMonitor isn't specific to any
particular monitoring stack — it's the `monitoring.coreos.com/v1` API:

```nix
# packages/valkey/default.nix — wiring, not config
{ scope, config, lib, monitoring ? null }:
let
  hasMonitoring = monitoring != null;
in
self: {
  serviceMonitor = if hasMonitoring then scope.mkResource { ... } else null;
}
```

The package says `monitoring ? null` — a generic name. The kube-prometheus-stack
instance has `aliases = [ "monitoring" ]`, so DI resolves it. If someone swaps
out kube-prometheus-stack for a different monitoring solution that also creates
the `monitoring.coreos.com/v1` CRD, they just give it the same alias. The
package doesn't care what monitoring stack it is — it just needs something that
makes ServiceMonitor resources meaningful.

If monitoring is enabled → the instance exists → DI resolves it → the package
creates the ServiceMonitor. If monitoring is disabled → no instance → DI
returns null → no ServiceMonitor. No `scope.clusterConfig` needed.

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

**Future direction:** The DI dependency graph already knows that python-app
depends on postgres (because of the function arg). Fine-grained network
policies — per service, per port — could be derived directly from the DI graph.
If python-app takes `postgres` as a DI dependency, the system knows to allow
traffic from python-app pods to the postgres port. This is a natural extension
once the DI system is stable, but the namespace-level tenant model is the
practical first step.

### Use Case 2C: TLS Issuers as DI-Resolved Infrastructure

**Today** — Every ingress hardcodes `clusterIssuer = "northwind"`. If the issuer
name changes, 8+ places must be updated.

**This is wiring, not configuration.** The python-app package depends on a
cluster-issuer. The DI system should resolve it.

The cluster-issuers instance exposes both the issuer name and a **transformer
function** — a function that takes a resource and returns it with the right
annotations added. This fits the DSL principle that resources are rich objects:

```nix
# packages/cluster-issuers/default.nix
{ scope, config, lib }:
let cfg = config; in
self: {
  out = {
    name = cfg.mainIssuer;
    # Transformer: annotate any resource for TLS
    withCert = resource: resource // {
      metadata = (resource.metadata or {}) // {
        annotations = (resource.metadata.annotations or {}) // {
          "cert-manager.io/cluster-issuer" = self.out.name;
        };
      };
    };
  };
  # ... ClusterIssuer resources ...
}
```

Consuming packages use the pipe operator with the transformer:

```nix
# packages/python-app/default.nix
{
  scope, config, lib,
  postgres ? null,
  valkey ? null,
  cluster-issuer ? null,
}:
let
  cfg = config;
in
self: {
  ingress = if cfg.ingress.enabled then
    scope.mkResource {
      kind = "Ingress";
      spec.rules = map (h: {
        host = h.host;
        http.paths = h.paths;
      }) cfg.ingress.hosts;
    }
    |> (if cluster-issuer != null then cluster-issuer.out.withCert else lib.id)
  else null;
}
```

No manual annotation plumbing. The cluster-issuer exposes `withCert`, the
package pipes through it. If there's no cluster-issuer in the cluster, the pipe
is identity — no TLS annotation, no crash. The dependency is tracked via string
context automatically.

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

**This is wiring, not configuration.** Packages that need storage declare a DI
dependency on a storage provider. There is no `config.storage.storageClass`
option that shadows DI — if a package needs a different storage class than the
default, the cluster operator overrides the DI via `deps`, not via config:

```nix
# packages/stackgres-cluster/default.nix
{
  scope, config, lib,
  storage-class ? null,  # ← DI resolves to the storage-classes instance
}:
let
  cfg = config;
in
self: {
  pvc = scope.mkResource {
    kind = "PersistentVolumeClaim";
    spec = {
      storageClassName =
        if storage-class != null then storage-class.out.defaultClass
        else null;
      resources.requests.storage = cfg.storage.size;
    };
  };
}
```

The package only talks to DI. No config-vs-DI priority dance, no
`effectiveStorageClass` boilerplate. If the cluster operator wants a specific
instance to use a different storage class:

```nix
# fragments/nw1/shopfront.nix
shopfront-prod.postgres = {
  package = packages.stackgres-cluster;
  packageType = "postgres";
  config = {
    instances = 3;
    storage.size = "400Gi";
    # No storageClass in config — that's wiring, not behavior
  };
  # Need a different storage class? Override the DI.
  deps = {
    storage-class = ref.kube-system.localzfs-no-retain;
  };
};
```

Same principle as nixpkgs `.override { }` — wiring overrides live in `deps`,
behavioral values live in `config`. One source of truth for each.

The storage-class package can also expose a transformer, like cluster-issuer:

```nix
# packages/storage-classes/default.nix
self: {
  out = {
    defaultClass = cfg.defaultClass;
    withStorageClass = resource: resource // {
      spec = (resource.spec or {}) // {
        storageClassName = self.out.defaultClass;
      };
    };
  };
}
```

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

The priority-classes package creates PriorityClass resources from the merged
config. Teams declare what they need, the platform aggregates.

Attaching priority classes to workloads is still a `priorityClassName` string
in the instance config today. This could become a DI reference to a
priority-class resource in the future, making the dependency tracked — but the
string works and matches the K8s manifest field directly, so it's not urgent.

---

## Persona 3: Service Maintainer (Package Author)

**Responsibility:** Maintains a kix package (e.g., python-app, valkey,
stackgres-cluster). Defines what the package needs (DI dependencies), what
config options control its behavior, and what resources it produces.

The package author's power and responsibility is limited by design. They expose
knobs (DI args and config options). The cluster operator turns them. This fights
the Helm problem where charts are over-reliant on very specific implementations
— in kix, the cluster operator can override everything.

### Use Case 3A: Package Declares Dependencies via DI

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
  cfg = config;
in
self: {
  configmap = scope.mkResource {
    kind = "ConfigMap";
    data = {}
      // lib.optionalAttrs (postgres != null) {
        DATABASE_HOST = postgres.out.fqdn;
      }
      // lib.optionalAttrs (valkey != null) {
        VALKEY_HOST = valkey.out.fqdn;
      };
  };

  ingress = if cfg.ingress.enabled then
    scope.mkResource {
      kind = "Ingress";
      spec.ingressClassName =
        if ingress-nginx != null
        then ingress-nginx.out.ingressClassName
        else cfg.ingress.className;
      spec.rules = map (h: {
        host = h.host; http.paths = h.paths;
      }) cfg.ingress.hosts;
    }
    |> (if cluster-issuer != null then cluster-issuer.out.withCert else lib.id)
  else null;
}
```

No hardcoded issuer names. No hardcoded ingress class names. The DI system
resolves them. The dependency graph tracks them automatically.

The ingress class comes from DI when available, falls back to config when not.
This is one of the few cases where a config fallback makes sense — the ingress
class name is a plain string in the K8s spec, and a cluster might not have
ingress-nginx as a DI-able instance (e.g., cloud-managed ingress). But storage
classes and issuers are always cluster-provisioned, so those should be DI-only.

### Use Case 3B: Package Exposes Typed Options

If the valkey maintainer wants typed config validation:

```nix
# packages/valkey/_kixOptions.nix
{ lib, ... }: {
  options = {
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 3;
      # Checks work here too — guards against nonsensical values
      check = x: x >= 0;
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

Now setting `config.replicaCount = "three"` is a type error instead of a
silent bug discovered at deploy time. The `check` function catches
`replicaCount = -3` too.

Note: these are all **configuration** options (values that control behavior).
Infrastructure dependencies (storage class, monitoring stack) are DI, not
options.

### Use Case 3C: Package Exposes Transformer Functions

Package authors can expose transformer functions through `out` that let
consumers pipe resources through domain-specific operations:

```nix
# packages/cluster-issuers/default.nix — exposes out.withCert
# packages/storage-classes/default.nix — exposes out.withStorageClass
# packages/ingress-nginx/default.nix — exposes out.withIngressClass
```

These are optional conveniences. Consumers can always access `.out.name` or
`.out.defaultClass` directly. The transformer pattern just eliminates the
repeated `lib.optionalAttrs` boilerplate and works cleanly with the pipe
operator.

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
  shopfrontExtensions = [ "pgcrypto" "citext" "pg_trgm" ];

  # Module generator — one function produces a full environment
  mkShopfrontEnv = envName: envConfig: { lib, config, ... }: {

    config.tenants.acme.namespaces = [ envName ];
    config.priorities.${envName} = { value = envConfig.priority; };

    # DNS rewrites — declared once, consumed by both CoreDNS and Ingress
    config.dnsRewrites = map (h:
      { hostname = h.host; target = envConfig.ingressTarget or "public"; }
    ) envConfig.hosts;

    config.instances.${envName} = {
      "${envName}-general" = {
        package = packages.python-app;
        packageType = "python-app";
        config = {
          appName = "shopfront";
          environment = envConfig.environment;
          priorityClassName = envName;
          backend.image = {
            repository = "ghcr.io/northwind/shopfront/web";
            tag = envConfig.imageTag;
          };
          backend.replicaCount = envConfig.replicas;
          ingress = {
            enabled = true;
            # No clusterIssuer — DI wires it automatically
            # No className — DI wires it from the ingress-nginx instance
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
    (mkShopfrontEnv "shopfront-demo" {
      environment = "demo";
      imageTag = "v26.12.4";
      replicas = 2;
      pgInstances = 1;
      pgStorage = "50Gi";
      valkeyReplicas = 1;
      priority = 500;
      backup = {
        bucket = "northwind-stackgres-demo-shopfront";
        credentialsSecret = "stackgres-storage-creds-shopfront";
      };
      hosts = [
        { host = "demo.packwise.example"; paths = [{ path = "/"; service = "backend"; }]; }
      ];
    })
  ];
}
```

**What changed vs today:**
- No `clusterIssuer = "northwind"` — wired via DI
- No `className = "public"` — wired via DI
- No `storageClass = "localzfs-retain"` — wired via DI
- Team declares tenants + priorities — platform aggregates automatically
- DNS rewrites declared alongside hosts — no separate manual list in CoreDNS config
- Fragment is independent — team can edit without touching cluster definition
- Three environments generated from one `mkShopfrontEnv` function — differences
  are just the parameters

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

This is the answer to the DI-vs-config tension: there is no tension. Config
is for values (replica counts, image tags). Deps is for wiring (which issuer,
which storage class). If you're tempted to add `config.storage.storageClass`
as a way to override what storage class an instance uses — use
`deps.storage-class` instead. One mechanism for each concern.

### Use Case 4C: DI Resolution and Control

How does the team know what gets DI-ed where? The resolution order is:

1. **Explicit `deps` override** — always wins
2. **Same-namespace match** — if exactly one instance in the same namespace has
   a matching packageType or alias
3. **Cluster-wide unique match** — if exactly one instance anywhere in the
   cluster matches
4. **Nix default** — the `? null` or `? valkey` fallback in the package
5. **Eval error** — if there's no match and no default

If two instances match (e.g., two ingress controllers, no explicit override),
the DI system raises an error: "ambiguous resolution for `ingress-nginx`,
specify `deps.ingress-nginx` explicitly." The cluster operator resolves it by
adding a `deps` entry. This is intentional — ambiguity should be loud, not
silently pick one.

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

  config.dnsRewrites = [
    { hostname = "app.ledgerly.example"; target = "public"; }
  ];

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
teams contribute to the same tenant/priority/dnsRewrite aggregation without
coordinating.

---

## Cross-Persona Interactions Summary

### What Goes Where

```
Configuration (module options)            Wiring (DI)
──────────────────────────────            ────────────
monitoring.enabled = true                 cluster-issuer → cluster-issuers instance
tenants.acme.namespaces = [...]      ingress-nginx → ingress controller instance
priorities.shopfront-prod.value = 1000      storage-class → storage-classes instance
dnsRewrites = [...]                       postgres → postgres instance
instance config: replicas, images, etc.   valkey → valkey instance
                                          monitoring → kube-prometheus-stack (via alias)
```

### Data Flow

```
   Module System (configuration)          DI System (wiring)
   ─────────────────────────────          ─────────────────────

   Platform declares options               Platform provides infra instances
   ─────────────────────────               ──────────────────────────────
   options.monitoring.enabled         →    instances.monitoring-system.kube-prometheus-stack
   options.tenants                    →    instances.kube-system.network-policies
   options.priorities                 →    instances.kube-system.priority-classes
   options.dnsRewrites                →    instances.kube-system.coredns

   Teams set options                       Teams declare instances
   ────────────────                        ──────────────────────
   config.monitoring.enabled = true        instances.shopfront-prod.shopfront = { ... }
   config.tenants.acme = [...]        instances.shopfront-prod.postgres = { ... }
   config.priorities.shopfront-prod = {...}
   config.dnsRewrites = [...]

   Module system aggregates                DI resolves dependencies
   ────────────────────────                ────────────────────────
   priorities → priority-classes config    python-app.cluster-issuer → cluster-issuers
   tenants → network-policies config       python-app.ingress-nginx → ingress-public-v2
   monitoring.enabled → condl instances    stackgres.storage-class → storage-classes
   dnsRewrites → coredns config            valkey.monitoring → kube-prometheus-stack
```

### Conflict Resolution

| Scenario | What Happens |
|----------|-------------|
| Two teams define same `(ns, instance)` | Module system merge error (collision detection) |
| Team and platform both set `replicaCount` | `mkDefault` (platform) loses to normal priority (team) |
| Platform forces a policy | `mkForce` wins over team settings |
| Two teams add namespaces to same tenant | Lists merge (both contributions preserved) |
| Ambiguous DI (two ingress controllers, no explicit override) | DI system error: "ambiguous, specify explicitly" |
| No cluster-issuer in cluster | DI returns null, package skips TLS (if `? null`) |
| Package says `valkey` but cluster has redis | Use `aliases = [ "valkey" ]` on redis, or `deps.valkey = ref...redis` |

---

## What the Module System IS For (Summary)

1. **Splitting a monolithic cluster file** into team-owned fragments
2. **Aggregating metadata** across fragments (tenants, priorities, DNS rewrites)
3. **Feature flags** that conditionally create instances (monitoring.enabled)
4. **Configuration values** for instances (replicas, images, env vars)
5. **Policy enforcement** via mkForce (platform overrides team settings)
6. **Typed config validation** via package-level option schemas with checks

## What the Module System is NOT For

1. **Wiring instances together** — that's DI (cluster-issuer, storage-class, etc.)
2. **Referencing instance outputs** — that's DI + string context tracking
3. **Config options that shadow DI** — no `config.storage.storageClass` when
   `deps.storage-class` exists. One mechanism per concern.
4. **Abstract dependency interfaces** — packages declare concrete deps (like
   nixpkgs), cluster operators substitute via `aliases` and `deps` overrides

---

## Open Design Question: Package-Level Config vs Instance-Level Config

### The Problem

Throughout this document, module options like `dnsRewrites` are aggregated from
fragments and then routed to a specific instance with explicit Nix code:

```nix
# fragments/nw1/infra.nix
config.instances.kube-system.coredns.config.dnsRewrites = config.dnsRewrites;
```

This works, but it hardcodes the namespace (`kube-system`) and instance name
(`coredns`). The platform module that offers the dnsRewrites abstraction is
tied to a specific cluster layout. If another cluster puts coredns in a
different namespace, or names it differently, the module breaks. The platform
team isn't just offering a reusable abstraction — they're offering a hard
implementation for a specific cluster.

This tension applies to any cross-cutting concern: DNS rewrites, monitoring
scrape config, network policy rules. The module declares an option, fragments
set it, but the last mile — routing the aggregated value to the right
instance — is hardcoded.

### Four Approaches

**Approach 1: packageDefaults** — The platform module targets a packageType
instead of a specific instance path. Config is merged (at `mkDefault` priority)
into every instance that matches:

```nix
# Reusable platform module — works on any cluster
{ packages, ... }: { config, lib, ... }: {

  options.dnsRewrites = lib.mkOption { /* ... */ };

  # Targets any instance with packageType "coredns", wherever it lives
  config.packageDefaults."coredns" = {
    servers = lib.mkDefault (buildServersFromRewrites config.dnsRewrites);
  };
}
```

The cluster operator places the coredns instance wherever they want:

```nix
# nw1 puts it in kube-system
config.instances.kube-system.my-coredns = {
  package = packages.coredns;
  packageType = "coredns";
  # servers config arrives via packageDefaults — no explicit wiring needed
};

# A different cluster could put it in dns-system with a different name
config.instances.dns-system.coredns-primary = {
  package = packages.coredns;
  packageType = "coredns";
  # same packageDefaults apply — the module is portable
};
```

Per-instance config still overrides packageDefaults (normal priority beats
`mkDefault`). If the cluster has two coredns instances, both get the config —
which for DNS rewrites is probably correct (all DNS servers should know all
rewrites).

**Approach 2: Package reads cluster config** — Inside the coredns package, it
reads `config.dnsRewrites` directly from the module tree:

```nix
# packages/coredns/default.nix
{ scope, config, lib, clusterConfig, ... }:
# clusterConfig.dnsRewrites available here
```

This is the NixOS model (service modules read other modules' options). But it
breaks package portability — the package is now coupled to the module schema.
A coredns package that reads `clusterConfig.dnsRewrites` can't be used in a
cluster that doesn't define that option. **Probably not the right fit for kix.**

**Approach 3: Config router** — Fragments request a capability (e.g., "I need a
DNS rewrite") and the system routes it to the "closest" or "most appropriate"
instance automatically:

```nix
# A fragment requests a DNS rewrite — system finds the right coredns
config.dnsRequests = [
  { hostname = "admin.packwise.example"; target = "private"; }
];
# → routed to closest coredns (same namespace? same tenant? cluster-wide?)
```

Most Kubernetes-native in spirit (service discovery for config). But complex to
implement and reason about. What does "closest" mean? What happens when routing
is ambiguous? **Interesting long-term direction but probably over-engineered for
now.**

**Approach 4: Explicit wiring** — The platform team writes one line of Nix to
route the aggregated option to the instance they know about:

```nix
config.instances.kube-system.coredns.config.dnsRewrites = config.dnsRewrites;
```

Simple, clear, works today. The platform team who declares the module option
also owns the routing. If they rename or move coredns, they update this one
line. But the module is cluster-specific, not reusable.

### Where Each Approach Fits

The approaches aren't mutually exclusive. They serve different use cases:

**packageDefaults (Approach 1)** is right for **reusable platform modules** —
abstractions meant to work across clusters without knowing where instances live.
The module targets a packageType, not a path. Good for:
- Cross-cutting policies: "every postgres gets version 16", "every valkey gets
  auth enabled"
- Aggregated config that should reach all instances of a type: DNS rewrites
  going to all coredns instances, scrape config going to all monitoring stacks

**Explicit wiring (Approach 4)** is right for **cluster-specific glue** — when
the platform team knows exactly which instance they're targeting and portability
isn't a concern. Good for:
- One-off cluster customisation
- Cases where only *one specific* instance should receive the config, not all
  instances of that type

The question for each cross-cutting concern is: **"Is this module meant to be
reusable across clusters, or is it cluster-specific?"** If reusable →
packageDefaults. If cluster-specific → explicit wiring.

### packageDefaults: Implementation Sketch

```nix
# Module option declaration
options.packageDefaults = lib.mkOption {
  type = lib.types.attrsOf lib.types.deferredModule;
  default = {};
  description = ''
    Config merged (at mkDefault priority) into every instance whose
    packageType matches the key. Per-instance config overrides.
  '';
};
```

During instance evaluation, before calling the package, the system merges
`packageDefaults.${inst.packageType}` into `inst.config`. Because it's
`mkDefault`, any per-instance config set at normal priority wins automatically.
`mkForce` in packageDefaults would override even per-instance config — useful
for enforcing cluster-wide policy.

### Open Questions

- **Multiple matches:** If a cluster has two coredns instances and
  packageDefaults sets `servers`, both get it. Is this always desirable? For
  DNS, yes. For something like "route this specific backup config to one
  specific postgres" — no, and that's a signal to use explicit wiring instead.

- **packageType vs aliases:** Should packageDefaults also match on aliases? If
  coredns has `aliases = [ "dns" ]`, should `packageDefaults."dns"` apply? This
  adds power but also ambiguity.

- **Priority layering:** With packageDefaults, the priority stack becomes:
  packageDefaults (`mkDefault`) < per-instance config (normal) < platform
  enforcement (`mkForce`). This is clean and matches NixOS conventions. But if
  namespace-scoped defaults are needed later, where do they sit in the priority
  order?
