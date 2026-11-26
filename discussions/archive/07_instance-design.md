# kixpkgs: Instances Design Document

## Executive Summary

This document describes the developer experience for `kixpkgs`, a Nix-based Kubernetes resource manager. The central abstraction is the **instance** — a configured deployment of a package into a namespace. Users declare instances grouped by namespace, point them at each other via `ref`, and the system produces a fully-tracked, topo-sorted resource DAG with correct cross-namespace dependencies.

The design has three layers:

1. **Packages** — reusable K8s application definitions, maintained by the community or internal teams. Analogous to nixpkgs derivations.
2. **Instances** — a package deployed with specific config into a specific namespace. Analogous to a NixOS service module like `services.nginx.enable = true`.
3. **Clusters** — a set of instances and namespaces that constitute a deployable unit. Analogous to a NixOS system configuration.

The user operates almost entirely at the instance layer. They never call `mkResource` directly, never wire namespaces manually, and never think about dependency tracking.

---

## Part 1: The Instance DX

### What the user writes

```nix
# clusters/production.nix
{ kixpkgs, packages }:

kixpkgs.buildCluster {

  namespaces = {
    production = {
      resourceQuota.hard = {
        "requests.cpu" = "20";
        "limits.memory" = "64Gi";
      };
    };
    data = {
      resourceQuota.hard = {
        "requests.storage" = "500Gi";
      };
    };
  };

  instances = { ref, ... }: {
    kube-system = {
      coredns = {
        package = kixpkgs.packages.coredns;
      };
    };

    data = {
      postgres = {
        package = kixpkgs.packages.postgresql;
        config = {
          storage = "100Gi";
          replicas = 3;
        };
      };
    };

    production = {
      api = {
        package = packages.acme-api;
        config = {
          image = "myregistry.io/api:v2.1.0";
          replicas = 5;
          database = ref.data.postgres;
          dns = ref.coredns;             # unambiguous — only one coredns
        };
      };

      worker = {
        package = packages.acme-worker;
        config = {
          database = ref.data.postgres;
          api = ref.production.api;
        };
      };
    };
  };
}
```

That's the entire user-facing API. Everything else — namespace resources, dependency tracking, cross-namespace FQDN resolution, deploy ordering — is derived.

### Core design principles

**1. Instances are the unit of deployment, not resources.**

Users don't think in individual ConfigMaps and ServiceAccounts. They think "I need a postgres" and "I need my app talking to that postgres." The instance is the atom from the user's perspective. Resources are implementation details inside packages.

**2. Instances are scoped by namespace.**

Instances are nested under their namespace: `production.api`, `data.postgres`, `kube-system.coredns`. Two teams can both define a `postgres` instance — as long as they're in different namespaces, there's no conflict. This mirrors how K8s itself scopes resources and eliminates the need for team-prefixed naming conventions.

**3. Cross-references use `ref`, not raw instance paths.**

When the user writes `ref.data.postgres`, they get the fully-evaluated postgres instance — its `main` resource's `ref`, `out`, `fqdn`, and the entire transitive closure. The package author uses these to build connection strings, env vars, etc. The user never needs to know which specific resource inside postgres is the "right one" to reference.

For instances with a unique name across all namespaces, the short form `ref.coredns` works. If the name is ambiguous, the system errors with a helpful message listing the namespaces where it exists.

**4. Namespaces are implied by usage.**

If you list instances under `production`, the namespace `production` exists. The separate `namespaces` block is purely about policy (quotas, limits, netpols), not about declaring existence. A namespace with no special policy doesn't need to appear in `namespaces` at all.

**5. Config is freeform but scoped.**

Each package defines what it expects in `config`. There's no global `values.yaml` — each instance has its own `config` attrset that only that package sees. Cross-instance references live in config too, as `ref.namespace.instance`.

### The `ref` system

The `instances` attribute is a function that receives `{ ref, ... }` where `ref` is a structured accessor into all evaluated instances across all namespaces.

```nix
instances = { ref, ... }: {
  production = {
    api = {
      config = {
        # Full path — always works, explicit namespace
        database = ref.data.postgres;

        # Short path — works when the name is globally unique
        dns = ref.coredns;
      };
    };
  };
};
```

`ref.data.postgres` gives you the final evaluated postgres instance, including its `.ref`, `.out`, `.fqdn`, `.closure` — everything. The fixpoint ties all instances together so references resolve to final values.

Ambiguous short refs produce a clear error:

```
error: ambiguous ref 'postgres' — found in namespaces: data, production, staging.
       Use ref.data.postgres, ref.production.postgres, or ref.staging.postgres.
```

### Instance-level overrides

For the common case where the user needs to tweak one resource inside a package:

```nix
instances = { ref, ... }: {
  kube-system = {
    coredns = {
      package = kixpkgs.packages.coredns;

      # Override individual parts — like overrideAttrs
      parts = self: super: {
        workload = self.scope.mkResource {
          apiVersion = "apps/v1";
          kind = "StatefulSet";
          name = "${self.scope.instanceName}-coredns";
          spec = {
            replicas = 3;
            serviceName = self.service.ref;
            selector.matchLabels = super.workload.spec.selector.matchLabels;
            template = super.workload.spec.template;
            volumeClaimTemplates = [{
              metadata.name = "data";
              spec = {
                accessModes = [ "ReadWriteOnce" ];
                resources.requests.storage = "1Gi";
              };
            }];
          };
        };
      };
    };
  };
};
```

The `parts` key is optional. When present, it's applied as an overlay on the package's inner fixpoint. `super` gives you the original parts, `self` gives you the final (overridden) parts.

### Error messages

The system produces clear errors at evaluation time, not deploy time:

```
error: instance 'api' in namespace 'production' references ref.data.redis,
       but no instance named 'redis' exists in namespace 'data'.
       Instances in 'data': postgres

error: ambiguous ref 'postgres' — found in namespaces: data, production, staging.
       Use ref.data.postgres, ref.production.postgres, or ref.staging.postgres.

error: package for instance 'api' in namespace 'production' does not define
       a 'main' resource. Every package must set 'main' to indicate its
       primary interface.

error: cycle detected in instance dependencies:
       production/api → data/postgres → production/api
       Instance cross-references must form a DAG.

error: instance 'postgres' in namespace 'data' is defined by both
       fragment 'backend-team' and fragment 'ml-team'.
       Only one fragment may define a given (namespace, instance) pair.
```

---

## Part 2: Environments — `mkEnv`

### The problem

Teams often need the same set of instances across multiple environments (dev, staging, prod) with only minor config differences — replica counts, storage sizes, image tags. Copy-pasting instance blocks violates DRY and drifts over time.

### The solution: instance sets stamped per environment

Define your instances once as **instance sets**, then stamp them into environments with `mkEnv`:

```nix
{ kixpkgs, packages }:

let
  # ── Instance sets: define once ────────────────────────────

  appStack = { ref, env }: {
    frontend = {
      package = packages.frontend;
      config = {
        database = ref."${env.name}-data".postgres;
        cdn = env.config.cdnUrl or null;
      };
    };
    api = {
      package = packages.backend-api;
      config = {
        database = ref."${env.name}-data".postgres;
        dns = ref.coredns;
      };
    };
  };

  dataStack = { ref, env }: {
    postgres = {
      package = packages.postgresql;
      config.storage = env.config.pgStorage or "10Gi";
    };
    redis = {
      package = packages.redis;
    };
  };

in kixpkgs.buildCluster {

  namespaces = {
    prod-app = { resourceQuota.hard."limits.cpu" = "40"; };
    prod-data = { resourceQuota.hard."requests.storage" = "500Gi"; };
    # dev namespaces need no policies — implied by usage
  };

  instances = { ref, ... }:
    # ── Shared infrastructure ───────────────────────────────
    {
      kube-system.coredns = {
        package = kixpkgs.packages.coredns;
      };
    }
    # ── Dev: replicas=1, small storage ──────────────────────
    // kixpkgs.mkEnv "dev" {
      defaults = { replicas = 1; };
      config = { pgStorage = "10Gi"; };
    } {
      app = appStack;
      data = dataStack;
    }
    # ── Prod: replicas=5, big storage ───────────────────────
    // kixpkgs.mkEnv "prod" {
      defaults = { replicas = 5; };
      config = {
        pgStorage = "200Gi";
        cdnUrl = "https://cdn.acme.com";
      };
    } {
      app = appStack;
      data = dataStack;
    };
}
```

### What `mkEnv` produces

For `mkEnv "dev" { defaults = { replicas = 1; }; } { app = appStack; data = dataStack; }`:

```
Namespaces created:
  dev-app
  dev-data

Instances created:
  dev-app/frontend    (replicas=1)
  dev-app/api         (replicas=1)
  dev-data/postgres   (replicas=1, storage=10Gi)
  dev-data/redis      (replicas=1)
```

For `mkEnv "prod" ...`:

```
Namespaces created:
  prod-app
  prod-data

Instances created:
  prod-app/frontend   (replicas=5)
  prod-app/api        (replicas=5)
  prod-data/postgres  (replicas=5, storage=200Gi)
  prod-data/redis     (replicas=5)
```

The namespace names are `${envName}-${setName}`. Refs within a set use the env-prefixed namespace: `ref."${env.name}-data".postgres`. Refs to shared infrastructure (like `ref.coredns`) work unchanged because they're outside the env scope.

### Per-instance overrides within an env

When prod needs tweaks beyond just defaults:

```nix
// kixpkgs.mkEnv "prod" {
  defaults = { replicas = 5; };
  config = { pgStorage = "200Gi"; };
  overrides = {
    app.api.config.replicas = 10;
    app.api.config.minAvailable = 3;
    data.postgres.config.backups = true;
  };
} {
  app = appStack;
  data = dataStack;
}
```

### Adding a new environment

One line stamps the entire stack:

```nix
// kixpkgs.mkEnv "canary" {
  defaults = { replicas = 1; };
  config = { pgStorage = "10Gi"; };
} {
  app = appStack;
  data = dataStack;
}
```

This creates `canary-app/frontend`, `canary-app/api`, `canary-data/postgres`, `canary-data/redis` — all with replicas=1 and small storage. Adding a new service to `appStack` automatically appears in every environment.

### The mental model

```
                 ┌──────────────────────────┐
                 │   Instance Sets           │
                 │   (define once)           │
                 │                           │
                 │   appStack:               │
                 │     frontend, api         │
                 │                           │
                 │   dataStack:              │
                 │     postgres, redis       │
                 └───────────┬──────────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
         mkEnv "dev"    mkEnv "prod"   mkEnv "canary"
         replicas=1     replicas=5     replicas=1
              │              │              │
              ▼              ▼              ▼
        dev-app/          prod-app/      canary-app/
          frontend          frontend       frontend
          api               api            api
        dev-data/         prod-data/     canary-data/
          postgres          postgres       postgres
          redis             redis          redis
```

`mkEnv` is a ~15 line user-space helper, not a new system concept. It composes with everything else — fragments, overrides, cross-references — because the output is just a regular nested instances attrset.

---

## Part 3: Package Authoring

### The package signature

A package is a single function. It takes three arguments, returns an attrset of resources.

```nix
# packages/coredns/default.nix
{ self, scope, config }:

{
  # ... resources ...
  main = self.someResource;
}
```

That's the entire contract:

- `self` — the final value of this attrset (for cross-referencing your own resources).
- `scope` — helpers for creating resources, bound to the instance's namespace.
- `config` — freeform attrset from the user's instance config.

The system wraps this in a fixpoint internally. The package author never needs to know the word "fixpoint." They just know that `self.configmap` gives them the final value of `configmap`, even if `configmap` also references `self.service`.

### Scope API

| Attribute | Description |
|---|---|
| `scope.instanceName` | The unique instance name from the cluster config |
| `scope.namespace` | The namespace resource (auto-injected into mkResource) |
| `scope.mkResource { ... }` | Create a namespaced resource (namespace injected automatically) |
| `scope.mkClusterResource { ... }` | Create a cluster-scoped resource (no namespace) |
| `scope.str [ parts ]` | Build a tracked string with dependency tracking |
| `scope.defaults config { ... }` | Merge user config with defaults, catch unknown keys |

### Config with defaults

Packages declare their config schema and defaults with `scope.defaults`:

```nix
{ self, scope, config }:

let cfg = scope.defaults config {
  image = "registry.k8s.io/coredns/coredns:v1.11.1";
  replicas = 2;
  corefile = ''
    .:53 {
      forward . /etc/resolv.conf
      cache 30
    }
  '';
  clusterIP = null;       # null = let K8s assign
}; in

{
  # Use cfg.image, cfg.replicas, etc.
}
```

`scope.defaults` merges user config over defaults. Unknown keys in the user's config can optionally produce a warning or error, catching typos at evaluation time rather than runtime.

### Full example: CoreDNS

```nix
# packages/coredns/default.nix
{ self, scope, config }:

let cfg = scope.defaults config {
  image = "registry.k8s.io/coredns/coredns:v1.11.1";
  replicas = 2;
  corefile = ''
    .:53 {
      errors
      health { latefatal }
      ready
      kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
      }
      forward . /etc/resolv.conf
      cache 30
      loop
      reload
      loadbalance
    }
  '';
};

labels = {
  "app.kubernetes.io/name" = "coredns";
  "app.kubernetes.io/instance" = scope.instanceName;
};

selectorLabels = {
  "k8s-app" = "kube-dns";
  "app.kubernetes.io/instance" = scope.instanceName;
};

in {

  # ── Configuration ──────────────────────────────────────────

  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    data.Corefile = cfg.corefile;
  };

  # ── RBAC ───────────────────────────────────────────────────

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    spec.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "endpoints" "services" "pods" "namespaces" ];
        verbs = [ "list" "watch" ];
      }
      {
        apiGroups = [ "discovery.k8s.io" ];
        resources = [ "endpointslices" ];
        verbs = [ "list" "watch" ];
      }
    ];
  };

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    spec = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = self.clusterRole.ref;
      };
      subjects = [{
        kind = "ServiceAccount";
        name = self.serviceAccount.ref;
        namespace = self.serviceAccount.namespace;
      }];
    };
  };

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    requires = [ self.clusterRoleBinding ];
  };

  # ── Workload ───────────────────────────────────────────────

  pdb = scope.mkResource {
    apiVersion = "policy/v1";
    kind = "PodDisruptionBudget";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    spec = {
      maxUnavailable = 1;
      selector.matchLabels = selectorLabels;
    };
  };

  workload = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    requires = [ self.pdb ];
    spec = {
      replicas = cfg.replicas;
      selector.matchLabels = selectorLabels;
      template = {
        metadata.labels = labels // selectorLabels;
        spec = {
          serviceAccountName = self.serviceAccount.ref;
          tolerations = [{
            key = "CriticalAddonsOnly";
            operator = "Exists";
          }];
          containers = [{
            name = "coredns";
            image = cfg.image;
            args = [ "-conf" "/etc/coredns/Corefile" ];
            resources = {
              requests = { cpu = "100m"; memory = "70Mi"; };
              limits = { memory = "170Mi"; };
            };
            ports = [
              { containerPort = 53; protocol = "UDP"; name = "dns"; }
              { containerPort = 53; protocol = "TCP"; name = "dns-tcp"; }
              { containerPort = 9153; protocol = "TCP"; name = "metrics"; }
            ];
            livenessProbe = {
              httpGet = { path = "/health"; port = 8080; };
              initialDelaySeconds = 60;
              timeoutSeconds = 5;
            };
            readinessProbe = {
              httpGet = { path = "/ready"; port = 8181; };
            };
            volumeMounts = [{
              name = "config-volume";
              mountPath = "/etc/coredns";
              readOnly = true;
            }];
          }];
          volumes = [{
            name = "config-volume";
            configMap = {
              name = self.configmap.ref;
              items = [{ key = "Corefile"; path = "Corefile"; }];
            };
          }];
        };
      };
    };
  };

  # ── Service ────────────────────────────────────────────────

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    outputs = {
      port = 53;
      metricsPort = 9153;
    };
    spec = {
      selector = selectorLabels;
      ports = [
        { name = "dns"; port = 53; protocol = "UDP"; }
        { name = "dns-tcp"; port = 53; protocol = "TCP"; }
        { name = "metrics"; port = 9153; protocol = "TCP"; }
      ];
    };
  };

  # ── Public Interface ───────────────────────────────────────

  main = self.service // {
    requires = [ self.workload ];
  };
}
```

### What makes a good package

**Uses `scope.instanceName` for all resource names.** This prevents collisions when two instances of the same package exist in different namespaces.

**Accepts config through `config` with `scope.defaults`.** Every tunable has a default. Unknown keys are caught early.

**Uses `scope.mkResource` and `scope.mkClusterResource`.** Never sets `namespace` manually.

**Declares `main`.** The resource other instances interact with. Typically a Service. `main` carries `requires` that pull in the workload so that pulling on `main` gets everything.

**Annotates inverted dependencies with `requires`.** SA → binding, workload → PDB, workload → HPA.

**Does not reference other instances directly.** Cross-instance references come through `config` at the user level. A package that needs a database accepts `config.database` (a ref to another instance), not `config.databaseHost` (a string).

---

## Part 4: Package Registries

### The `kixpkgs.packages` registry

`kixpkgs.packages` is an attrset of package functions, built from a directory of package definitions. Identical to how nixpkgs builds its top-level package set from `pkgs/` directories.

```
kixpkgs/
├── flake.nix
├── lib/
│   ├── k8s.nix          # core resource/ref/closure machinery
│   ├── eval.nix          # buildCluster, scope, instance evaluation
│   └── env.nix           # mkEnv helper
├── packages/
│   ├── coredns/
│   │   └── default.nix
│   ├── postgresql/
│   │   └── default.nix
│   ├── cert-manager/
│   │   └── default.nix
│   ├── nginx-ingress/
│   │   └── default.nix
│   └── ...
└── default.nix           # collects all packages
```

The collector:

```nix
# default.nix
{
  packages = let
    packageDirs = builtins.readDir ./packages;
    packageNames = builtins.attrNames
      (lib.filterAttrs (_: type: type == "directory") packageDirs);
  in lib.genAttrs packageNames (name:
    import ./packages/${name}
  );
}
```

This produces `kixpkgs.packages.coredns`, `kixpkgs.packages.postgresql`, etc. Each package is a function `{ self, scope, config } -> attrset` — the system calls it with the right arguments when evaluating an instance.

### External package registries

A package registry is just a flake that exports a `packages` attrset. Any flake can be a registry.

```nix
# The kixpkgs flake — the community registry
{
  description = "Community K8s packages for kixpkgs";

  outputs = { self, nixpkgs }: let
    lib = nixpkgs.lib;
    k8s = import ./lib/k8s.nix { inherit lib; };
  in {
    packages = import ./packages { inherit lib k8s; };
    lib = import ./lib { inherit lib k8s; };
  };
}
```

```nix
# An internal registry — same shape, different packages
# git+ssh://git.internal.company.com/platform/k8s-packages
{
  description = "Internal K8s packages for Acme Corp";

  inputs.kixpkgs.url = "github:kixpkgs/kixpkgs";

  outputs = { self, kixpkgs, nixpkgs }: {
    packages = {
      acme-api = import ./packages/acme-api;
      acme-worker = import ./packages/acme-worker;
      acme-gateway = import ./packages/acme-gateway;

      # An internal fork of a community package
      postgresql = import ./packages/postgresql-acme;
    };
  };
}
```

### Consuming multiple registries

```nix
# flake.nix for a team's cluster
{
  inputs = {
    kixpkgs.url = "github:kixpkgs/kixpkgs";
    internal.url = "git+ssh://git.internal/platform/k8s-packages";
    ml-pkgs.url = "git+ssh://git.internal/ml/k8s-packages";
  };

  outputs = { self, kixpkgs, internal, ml-pkgs }: {
    cluster = import ./cluster.nix {
      inherit kixpkgs;
      packages = {
        # Community packages
        inherit (kixpkgs.packages) coredns cert-manager nginx-ingress;

        # Internal packages
        inherit (internal.packages) acme-api acme-worker acme-gateway;

        # Use the internal fork of postgresql instead of community
        inherit (internal.packages) postgresql;

        # ML team's packages
        inherit (ml-pkgs.packages) jupyter mlflow;
      };
    };
  };
}
```

```nix
# cluster.nix
{ kixpkgs, packages }:

kixpkgs.buildCluster {
  instances = { ref, ... }: {
    kube-system = {
      coredns = { package = packages.coredns; };
    };
    data = {
      postgres = {
        package = packages.postgresql;      # internal fork
        config.storage = "200Gi";
      };
    };
    production = {
      api = {
        package = packages.acme-api;        # internal
        config.database = ref.data.postgres;
      };
    };
    ml = {
      jupyter = {
        package = packages.jupyter;         # from ml-team
        config.gpu = true;
      };
    };
  };
}
```

### Registry composition helpers

For the common case where you want all packages from a registry plus selective overrides:

```nix
packages = kixpkgs.lib.mergeRegistries [
  kixpkgs.packages                         # base: all community packages
  internal.packages                         # override: internal packages win
  { postgresql = internal.packages.postgresql; }  # explicit cherry-pick
];
```

For strict mode that rejects unintentional overlaps:

```nix
packages = kixpkgs.lib.mergeRegistriesStrict [
  kixpkgs.packages
  internal.packages
];
# error: Package registry conflict: 'postgresql' exists in multiple registries.
#        Use explicit selection.
```

### Package versioning

Registries are flake inputs. Versioning is handled by the flake lock:

```nix
inputs = {
  kixpkgs.url = "github:kixpkgs/kixpkgs/v0.3.0";          # pinned release
  internal.url = "git+ssh://git.internal/platform/k8s-packages?rev=abc123";  # pinned commit
  ml-pkgs.url = "git+ssh://git.internal/ml/k8s-packages";   # follows main
};
```

`nix flake update internal` bumps internal packages. `nix flake lock --update-input kixpkgs` updates just the community packages. The lock file records exact commits, so builds are reproducible.

---

## Part 5: Multi-Team Collaboration

### The problem

A cluster isn't owned by one team. Platform engineering owns the infrastructure. Application teams own their services. ML teams own their workloads. Everyone deploys to the same cluster but manages different pieces.

We need a model where:

- Teams work on their instances independently.
- The platform team controls namespaces, policies, and shared infrastructure.
- Changes to shared infrastructure are visible to consuming teams.
- The final cluster configuration is the merge of all teams' contributions.
- Conflicts are detected at evaluation time, not deploy time.

### Cluster fragments

Each team produces a **cluster fragment** — a partial cluster definition that declares its namespaces and instances. The platform team (or CI) merges fragments into the final cluster.

```nix
# teams/platform/fragment.nix
# Owned by: platform engineering
{ packages }:

{
  namespaces = {
    kube-system = {};
    ingress = {
      resourceQuota.hard."requests.cpu" = "4";
    };
    monitoring = {};
  };

  instances = { ref, ... }: {
    kube-system = {
      coredns = { package = packages.coredns; };
    };
    ingress = {
      nginx-ingress = {
        package = packages.nginx-ingress;
      };
    };
    monitoring = {
      prometheus = { package = packages.prometheus; };
    };
  };
}
```

```nix
# teams/backend/fragment.nix
# Owned by: backend team
{ packages }:

{
  namespaces = {
    production = {
      labels."team" = "backend";
    };
    staging = {
      labels."team" = "backend";
    };
  };

  instances = { ref, ... }: {
    data = {
      postgres = {
        package = packages.postgresql;
        config.storage = "100Gi";
      };
    };
    production = {
      api = {
        package = packages.acme-api;
        config = {
          replicas = 5;
          database = ref.data.postgres;
          ingress = ref.nginx-ingress;
        };
      };
    };
    staging = {
      api = {
        package = packages.acme-api;
        config = {
          replicas = 1;
          database = ref.data.postgres;
          ingress = ref.nginx-ingress;
        };
      };
    };
  };
}
```

```nix
# teams/ml/fragment.nix
# Owned by: ML team
{ packages }:

{
  instances = { ref, ... }: {
    ml = {
      jupyter = {
        package = packages.jupyter;
        config.gpu = true;
      };
      mlflow = {
        package = packages.mlflow;
        config.database = ref.data.postgres;   # backend team's DB
      };
    };
  };
}
```

### Merge rules

**Namespaces:** Multiple fragments can reference the same namespace. Labels and annotations are merged with `lib.recursiveUpdate` (last fragment wins on key conflicts). Policies from `namespacePolicies` (platform-owned, see below) always override fragment-level policy declarations. This ensures the platform team controls security and resource boundaries.

**Instances:** Scoped by `(namespace, instance-name)`. Two fragments contributing different instance names to the same namespace merge cleanly. Two fragments defining the same instance name in the same namespace is an error:

```
error: instance 'postgres' in namespace 'data' is defined by both
       fragment 'backend-team' and fragment 'ml-team'.
       Only one fragment may define a given (namespace, instance) pair.
```

Different fragments defining `api` in `production` and `api` in `ml` is fine — different namespaces.

**Cross-fragment references:** Work through `ref` as usual. The ML team's mlflow can reference `ref.data.postgres` without coordinating with the backend team directly. The merge makes it work. CI catches if someone removes an instance that others depend on.

### The assembly flake

```nix
# flake.nix — the cluster repo, owned by platform / SRE
{
  inputs = {
    kixpkgs.url = "github:kixpkgs/kixpkgs";
    internal.url = "git+ssh://git.internal/platform/k8s-packages";
    ml-pkgs.url = "git+ssh://git.internal/ml/k8s-packages";

    team-platform.url = "git+ssh://git.internal/teams/platform/k8s-fragment";
    team-backend.url = "git+ssh://git.internal/teams/backend/k8s-fragment";
    team-ml.url = "git+ssh://git.internal/teams/ml/k8s-fragment";
  };

  outputs = { self, kixpkgs, internal, ml-pkgs,
              team-platform, team-backend, team-ml }:
    let
      packages = kixpkgs.lib.mergeRegistries [
        kixpkgs.packages
        internal.packages
        ml-pkgs.packages
      ];

      fragments = [
        (team-platform.fragment { inherit packages; })
        (team-backend.fragment { inherit packages; })
        (team-ml.fragment { inherit packages; })
      ];

      # Platform team controls policies for all namespaces
      namespacePolicies = {
        production = {
          resourceQuota.hard = {
            "requests.cpu" = "20";
            "limits.memory" = "64Gi";
          };
          networkPolicies = [{ /* ... */ }];
        };
        data = {
          resourceQuota.hard."requests.storage" = "500Gi";
        };
      };

      clusterConfig = kixpkgs.lib.mergeFragments {
        inherit fragments namespacePolicies;
      };

    in {
      cluster = kixpkgs.lib.buildCluster clusterConfig;

      # Per-team deploy targets
      deploy = {
        platform = self.cluster.deployGroup [
          "kube-system/coredns"
          "ingress/nginx-ingress"
          "monitoring/prometheus"
        ];
        backend = self.cluster.deployGroup [
          "data/postgres"
          "production/api"
          "staging/api"
        ];
        ml = self.cluster.deployGroup [
          "ml/jupyter"
          "ml/mlflow"
        ];
      };

      # Validation and diffing
      apps.validate = kixpkgs.lib.mkValidateApp self.cluster;
      apps.diff = kixpkgs.lib.mkDiffApp self.cluster;
    };
}
```

Note that `deployGroup` now takes `"namespace/instance"` paths, matching the namespace-scoped instance model. Each team's deploy target includes its own instances plus all transitive dependencies — if the backend team's api depends on coredns, coredns is in the backend deploy group's closure.

### What a team's fragment flake looks like

```nix
# git+ssh://git.internal/teams/backend/k8s-fragment/flake.nix
{
  description = "Backend team K8s fragment";

  outputs = { self }: {
    fragment = { packages }: import ./fragment.nix { inherit packages; };
  };
}
```

Minimal. The team's repo contains `fragment.nix` and nothing else K8s-related. They don't need `kixpkgs` as an input — the platform flake provides everything.

### The monorepo alternative

For teams using a monorepo instead of separate fragment repos:

```
cluster-repo/
├── flake.nix
├── packages/                  # internal packages
│   ├── acme-api/
│   └── acme-worker/
├── teams/
│   ├── platform/
│   │   └── fragment.nix
│   ├── backend/
│   │   └── fragment.nix
│   └── ml/
│       └── fragment.nix
├── policies/
│   └── namespaces.nix         # platform-owned
└── clusters/
    ├── production.nix          # production assembly
    └── staging.nix             # staging assembly
```

CODEOWNERS enforces team boundaries:

```
/teams/platform/     @platform-team
/teams/backend/      @backend-team
/teams/ml/           @ml-team
/policies/           @platform-team
/clusters/           @platform-team
/packages/acme-api/  @backend-team
```

Assembly in the monorepo is just local imports instead of flake inputs:

```nix
# clusters/production.nix
{ kixpkgs, packages }:

let
  fragments = [
    (import ../teams/platform/fragment.nix { inherit packages; })
    (import ../teams/backend/fragment.nix { inherit packages; })
    (import ../teams/ml/fragment.nix { inherit packages; })
  ];
  namespacePolicies = import ../policies/namespaces.nix;

in kixpkgs.lib.buildCluster (
  kixpkgs.lib.mergeFragments { inherit fragments namespacePolicies; }
);
```

### CI/CD integration

```yaml
# .github/workflows/deploy.yaml
jobs:
  validate:
    steps:
      - run: nix run .#validate

  diff:
    steps:
      - run: nix run .#diff

  deploy-backend:
    needs: [validate, diff]
    if: contains(github.event.paths, 'teams/backend/')
    steps:
      - run: nix eval .#deploy.backend.manifests | kubectl apply -f -
```

A team's deploy includes its instances plus transitive deps. If postgres changed, it's included. If coredns didn't change and isn't in the diff, it's skipped.

### The `deployGroup` helper

`deployGroup` takes a list of `"namespace/instance"` paths, merges their closures, and produces a topo-sorted manifest list:

```nix
deployGroup = instancePaths:
  let
    instances = map (path:
      let parts = lib.splitString "/" path;
          ns = builtins.elemAt parts 0;
          name = builtins.elemAt parts 1;
      in evaluatedInstances.${ns}.${name}
        or (throw "deployGroup: instance '${path}' not found")
    ) instancePaths;

    allResources = lib.unique (
      lib.concatMap (inst: inst.closure) instances
    );

    sorted = topoSort allResources;

  in {
    resources = sorted;
    manifests = map (r: r.manifest) sorted;
  };
```

---

## Part 6: Complete API Reference

### `buildCluster`

```nix
buildCluster {
  namespaces = { <name> = { <namespace-policy-config> }; ... };    # optional
  instances = { ref, ... }: {
    <namespace> = {
      <instance> = { <instance-config> };
      ...
    };
    ...
  };
}
```

### `mkEnv`

```nix
mkEnv "<env-name>" {
  defaults = { ... };        # merged into every instance's config
  config = { ... };          # passed to instance sets as env.config
  overrides = {              # optional, per-set per-instance overrides
    <set>.<instance>.config.<key> = <value>;
  };
} {
  <set-name> = <instance-set-function>;
  ...
}
```

Produces a nested attrset where namespaces are `"${envName}-${setName}"` and instances are keyed within those namespaces.

### `mergeFragments`

```nix
mergeFragments {
  fragments = [ <fragment> ... ];
  namespacePolicies = { <ns> = { <policy> }; ... };    # optional, platform-owned
}
```

Returns a `{ namespaces, instances }` attrset suitable for `buildCluster`.

### `mergeRegistries` / `mergeRegistriesStrict`

```nix
mergeRegistries [ <registry> ... ]         # last wins on conflicts
mergeRegistriesStrict [ <registry> ... ]   # errors on conflicts
```

### Instance config

```nix
{
  package = <package function>;     # required
  config = { ... };                 # optional, freeform, passed to package
  parts = self: super: { ... };     # optional, override individual resources
}
```

Namespace is implied by the key under which the instance is nested.

### Namespace policy config

```nix
{
  labels = { ... };                 # optional
  annotations = { ... };            # optional
  resourceQuota = { hard = { ... }; };  # optional
  limitRange = { limits = [{ ... }]; }; # optional
  networkPolicies = [{ ... }];      # optional
}
```

### Package signature

```nix
{ self, scope, config }:
{
  <part-name> = scope.mkResource { ... };
  main = self.<some-part>;                    # required
}
```

### Instance set signature (for `mkEnv`)

```nix
{ ref, env }:
{
  <instance-name> = {
    package = <package>;
    config = { ... };
  };
  ...
}
```

`env.name` is the environment name, `env.config` is the env-level config, `env.defaults` is the defaults merged into every instance.
