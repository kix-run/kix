# Writing kix Package Definitions

This guide walks you through writing package definitions for kix, from first
principles to advanced patterns. If you're coming from Helm, there's a
dedicated migration section near the end — but reading the earlier sections
first will give you the mental model you need.

---

## 1. Your First Package

A kix package is a Nix attribute set with `options` and a `build` function that
returns a set of Kubernetes resources. Here's the minimal shape:

```nix
{ scope, lib, kix }:
{
  options = {
    image = lib.mkOption { type = lib.types.str; default = "nginx:1.27"; };
    replicaCount = lib.mkOption { type = lib.types.int; default = 1; };
  };

  build = { self, config, clusterConfig }: {
    deployment = scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "${scope.instanceName}-myapp";
      spec = {
        replicas = config.replicaCount;
        selector.matchLabels = scope.selectorLabels;
        template = {
          metadata.labels = scope.selectorLabels;
          spec.containers = [{
            name = "myapp";
            image = config.image;
          }];
        };
      };
    };

    service = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "${scope.instanceName}-myapp";
      requires = [ self.deployment ];
      spec = {
        selector = scope.selectorLabels;
        ports = [{ port = 80; targetPort = 8080; }];
      };
    };

    root = self.service;
  };
}
```

Three things to notice:

1. **The function signature** — `{ scope, lib, kix }` gives you the scope,
   nixpkgs lib, and kixlib helpers. Dependencies on other packages are
   additional args.

2. **`options` + `build`** — packages declare typed options with `lib.mkOption`
   defaults. The `build` function receives `{ self, config, clusterConfig }`
   where `config` has the evaluated options.

3. **`root`** — this is what consumers of your package see. When another
   package depends on yours, they get `root`'s `.fqdn` and `.out`.

### What `scope` gives you

| Attribute | Purpose |
|---|---|
| `scope.mkResource` | Create a namespaced K8s resource |
| `scope.mkClusterResource` | Create a cluster-scoped resource (no namespace) |
| `scope.mkDeployment` | Create a Deployment (auto-wires selector/template labels) |
| `scope.mkStatefulSet` | Create a StatefulSet (auto-wires selector/template labels) |
| `scope.mkDaemonSet` | Create a DaemonSet (auto-wires selector/template labels) |
| `scope.instanceName` | The unique instance name (set by the cluster config) |
| `scope.namespaceName` | The namespace this instance lives in |
| `scope.namespace` | The Namespace resource itself (for dependency tracking) |
| `scope.selectorLabels` | Auto-derived selector labels for this instance |
| `scope.forNamespace` | Get a scope for a different namespace (cross-namespace resources) |
| `scope.rbac` | RBAC DSL (see RBAC_DSL.md) |
| `scope.mkCRD` | Create a CRD resource with builder outputs |
| `scope.mkCRDRef` | Reference an external CRD (no manifest, just builders) |
| `scope.mkCR` | Create a custom resource from a CRD |

---

## 2. Resources Are Store Paths

This is the single most important concept in kix.

When you call `scope.mkResource { ... }`, kix doesn't just build a YAML
manifest — it creates a **content-addressed Nix store path**. The hash of that
store path depends on the resource's content (apiVersion, kind, spec, labels,
annotations, etc.) and on every other resource referenced inside it.

When you write:

```nix
spec.template.spec.serviceAccountName = "${self.serviceAccount}";
```

Nix embeds the ServiceAccount's store path into the Deployment's manifest.
This does two things:

1. **Nix automatically records the dependency** via string context — no custom
   tracking, no annotations, no tree walkers.
2. **The Deployment's hash changes when the ServiceAccount changes** — this
   is the Merkle DAG property. Changes propagate through the entire graph.

At deploy time, a post-processing step replaces all store paths with actual
K8s resource names. You never see store paths in the final YAML.

**Key takeaway**: if you interpolate a resource with `${}`, the dependency is
tracked. Automatically. Always.

---

## 3. The Self Fixpoint

The `self` parameter (received by `build`) is a Nix fixpoint (`lib.fix`).
Every attribute in your build can reference any other attribute through `self`,
regardless of definition order:

```nix
build = { self, config, clusterConfig }: {
  # Defined first, but references self.clusterRole (defined later)
  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-myapp";
    extra.roleRef = {
      apiGroup = "rbac.authorization.k8s.io";
      kind = "ClusterRole";
      name = "${self.clusterRole}";    # ← forward reference, works fine
    };
    extra.subjects = [{
      kind = "ServiceAccount";
      name = "${self.serviceAccount}";  # ← also a forward reference
      namespace = scope.namespaceName;
    }];
  };

  serviceAccount = scope.mkResource { ... };
  clusterRole = scope.mkClusterResource { ... };

  # ...
};
```

Nix evaluates lazily, so circular *definitions* work as long as the actual
*values* aren't circular. A ClusterRoleBinding referencing a ServiceAccount
that doesn't reference the ClusterRoleBinding back is perfectly fine.

---

## 4. Setting Up `root`

`root` defines your package's public interface. It can be either a resource
directly or a `{ resource, requires }` attrset:

```nix
# Simple: root IS the resource
root = self.service;

# With requires: root exposes the service, but ensures the deployment is included
root = {
  resource = self.service;
  requires = [ self.deployment ];
};
```

### What goes in `root.requires`?

`root.requires` is for resources that are **top-level entry points** not
reachable from `root.resource` through interpolation or other `requires`
chains. In practice this is rare — it's mainly for packages that expose
**multiple independent services**:

```nix
# A package with two separate services (e.g., app + admin panel)
root = {
  resource = self.appService;
  requires = [ self.adminService ];
};
```

For the common case of a Service that selects a Deployment via labels, use
`requires` plus matching selector labels (typically `scope.selectorLabels`):

```nix
service = scope.mkResource {
  apiVersion = "v1";
  kind = "Service";
  name = "${scope.instanceName}-myapp";
  requires = [ self.deployment ];
  spec.selector = scope.selectorLabels;
  spec.ports = [{ port = 80; }];
};

root = self.service;
```

If one service depends on another within the same package, you can express
that directly:

```nix
adminService = scope.mkResource {
  # ...
  requires = [ self.adminDeployment ];
};

appService = scope.mkResource {
  # ...
  requires = [ self.appDeployment self.adminService ];
  # app needs admin to be running too
};

root = self.appService;
# adminService is pulled in through appService's requires chain
```

### What consumers see

When another package depends on yours, they get the evaluated instance which
exposes:

- `.fqdn` — the DNS name of the root resource (e.g., `myapp.mynamespace.svc.cluster.local`)
- `.out` — named outputs (ports, database names, etc.)
- The full evaluated parts, if they need deeper access

---

## 5. Automatic Dependency Tracking (Forward Closure)

Starting from `root`, the system walks the dependency graph using BFS:

1. Look at the root resource's manifest — find all embedded store paths (from `${}` interpolations)
2. Follow each resource's `requires` list
3. Repeat for each discovered resource
4. Everything reachable is in the **forward closure** — these resources will be deployed

Example:

```
Service (root)
  │
  ├── requires ──→ Deployment
  │                   │
  │                   ├── ${self.serviceAccount} ──→ ServiceAccount
  │                   │
  │                   └── ${self.configmap} ──→ ConfigMap
  │
  └── (auto, via scope) ──→ Namespace
```

The Service carries a `requires` to the Deployment (because Services select
Deployments via labels, not `${}` references). The Deployment interpolates the
ServiceAccount and ConfigMap names, so those are tracked automatically.

---

## 6. When to Use `requires`

You need explicit `requires` when a Kubernetes relationship isn't expressed
through a `${}` interpolation in the manifest. The most common cases:

| Relationship | Tracked by `${}` ? | Needs `requires`? |
|---|---|---|
| Deployment → ServiceAccount (via `serviceAccountName`) | Yes, use `self.sa.out.name` | No |
| Deployment → ConfigMap (via volume mount name) | Yes, use `"${self.cm}"` | No |
| Service → Deployment (via label selector) | No — selectors are plain labels | **Yes** |
| PDB → Deployment (via label selector) | No — selectors are plain labels | **Yes** |
| HPA → Deployment (via `scaleTargetRef`) | No — name is a plain string | **Yes** |

Use `requires` for label-selector relationships (Service → Deployment) and
name-based references that don't support `${}` interpolation (HPA
`scaleTargetRef`).

Place the `requires` on the resource that *needs* the other:

```nix
workload = scope.mkResource {
  apiVersion = "apps/v1";
  kind = "Deployment";
  name = "${scope.instanceName}-myapp";
  requires = [
    self.clusterRoleBinding   # RBAC must exist
  ]
  ++ lib.optional config.hpa.enabled self.hpa     # only if enabled
  ++ lib.optional config.pdb.enabled self.pdb;    # only if enabled
  spec = {
    template.spec.serviceAccountName = self.serviceAccount.out.name;  # tracked via .out
    # ...
  };
};
```

---

## 7. Inverse Dependencies

Here's where things get clever. Sometimes a resource isn't in the forward
closure (not reachable from `root`) but it **references** something that is.
The system detects this automatically and pulls it in as an **inverse
dependency**.

The classic example is RBAC:

```nix
build = { self, config, clusterConfig }: {
  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-myapp";
  };

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-myapp";
    extra.rules = [ ... ];
  };

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-myapp";
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = self.clusterRole.out.name;       # references ClusterRole
      };
      subjects = [{
        kind = "ServiceAccount";
        name = self.serviceAccount.out.name;     # references ServiceAccount
        namespace = scope.namespaceName;
      }];
    };
  };

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-myapp";
    spec.template.spec.serviceAccountName = self.serviceAccount.out.name;
    # ...
  };

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${scope.instanceName}-myapp";
    requires = [ self.deployment ];
    spec.selector = scope.selectorLabels;
    spec.ports = [{ port = 80; }];
  };

  root = self.service;
};
```

Here's how the system resolves this:

```
Forward closure (starting from Service):
  Service → (requires) → Deployment → (.out) → ServiceAccount
                                      (.out) → Namespace (via scope)

Not in forward closure:
  ClusterRoleBinding — BUT it references ServiceAccount (which IS in the closure)
  ClusterRole — no reference to anything in the closure

Inverse dependency detection:
  ClusterRoleBinding references ServiceAccount → pulled in as inverse dep

Now ClusterRoleBinding is in the closure, and IT references ClusterRole via .out →
  ClusterRole gets pulled in as a forward dep of ClusterRoleBinding
```

**Result**: everything gets deployed, and you didn't need a single `requires`
for RBAC. The ClusterRoleBinding's `.out` references to the ServiceAccount are
enough for the system to figure it out.

### The general intuition

1. Add all your resources to `self`
2. Set `root` to whatever consumers connect to (usually a Service)
3. Add `requires` to your Service for resources selected by labels (like
   Deployments)
4. Use `${}` interpolation or `.out` access everywhere you can — Nix tracks it automatically
5. Resources that reference something in the closure get pulled in as inverse
   deps, and their own references pull in further resources

The full chain from the example:

```
Service ──requires──→ Deployment ──.out──→ SA ←──.out── CRB ──.out──→ ClusterRole
  │                                                      ↑
  root                                             (inverse dep:
                                                    references SA
                                                    which is in the
                                                    forward closure)
```

---

## 8. Optional and Conditional Resources

Use `if/then/else null` for resources that depend on configuration:

```nix
hpa = if config.hpa.enabled then scope.mkResource {
  apiVersion = "autoscaling/v2";
  kind = "HorizontalPodAutoscaler";
  name = "${scope.instanceName}-myapp";
  spec = {
    scaleTargetRef = {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "${scope.instanceName}-myapp";  # plain string — needs requires
    };
    minReplicas = config.hpa.minReplicas;
    maxReplicas = config.hpa.maxReplicas;
    metrics = config.hpa.metrics;
  };
} else null;
```

Null resources are automatically filtered out of the closure. Use
`lib.optional` in `requires` lists to match:

```nix
workload = scope.mkResource {
  # ...
  requires = [
    self.clusterRoleBinding
  ]
  ++ lib.optional config.hpa.enabled self.hpa
  ++ lib.optional config.pdb.enabled self.pdb;
  spec.replicas = if config.hpa.enabled then null else config.replicaCount;
};
```

---

## 9. Using Dependencies (Other Packages)

To depend on another package, add its name as a function argument:

```nix
{ scope, lib, kix, postgres }:

{
  options = { ... };

  build = { self, config, clusterConfig }: {
    deployment = scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "${scope.instanceName}-api";
      spec.template.spec.containers = [{
        name = "api";
        image = config.image;
        env = [
          { name = "DATABASE_HOST"; value = postgres.fqdn; }
          { name = "DATABASE_PORT"; value = postgres.out.port; }
        ];
      }];
    };
    # ...
  };
}
```

### How resolution works

When the cluster evaluates your package, it resolves `postgres` using
DNS-like rules:

1. **Same namespace** — if there's exactly one `postgres`-typed instance in
   your namespace, use it
2. **Cluster-wide** — if there's exactly one `postgres`-typed instance
   anywhere, use it
3. **Nix default** — if your arg has a `? default`, fall back to that
4. **Error** — no candidates found

### Fine-grained dependency aliasing

You can use Nix default arguments to express "use this specific service if
available, otherwise fall back":

```nix
{ scope, lib, kix, redis, sessionStore ? redis, cache ? redis }:

{
  options = { ... };

  build = { self, config, clusterConfig }: {
    deployment = scope.mkResource {
      # ...
      spec.template.spec.containers = [{
        name = "myapp";
        image = config.image;
        env = [
          { name = "CACHE_HOST";   value = cache.fqdn; }
          { name = "SESSION_HOST"; value = sessionStore.fqdn; }
        ];
      }];
    };
    # ...
  };
}
```

Here `redis` is a required dependency — it must exist in the cluster. But
`sessionStore` and `cache` are optional overrides: if the cluster has a
dedicated instance with a matching alias, it will be used for sessions;
otherwise it falls back to `redis`. Same for `cache`. This lets you start
simple (one Redis for everything) and split later without changing the package.

At the cluster level, you'd wire this up as:

```nix
# Simple: one valkey for everything
instances = {
  backend = {
    redis = { package = packages.valkey; aliases = [ "redis" ]; };
    api   = { package = packages.myApi; };
  };
};

# Later: dedicated instances
instances = {
  backend = {
    redis         = { package = packages.valkey; aliases = [ "redis" ]; };
    session-store = { package = packages.valkey; aliases = [ "sessionStore" ]; };
    api           = { package = packages.myApi; };
  };
};
```

In the second configuration, the `api` package automatically picks up
`session-store` for its `sessionStore` argument via DI resolution (it
matches the alias), while `cache` still falls back to `redis`.

Note: The instance function form `{ ref, ... }:` is still valid for explicit
cross-instance wiring.

### Dependency values carry context

When you use `postgres.fqdn` or `postgres.out.port`, those values carry the
store path context of the postgres package. This means Nix automatically
tracks your package as depending on postgres — no manual wiring needed.

### Depending on external (non-kix) services

If the service your package depends on already exists in the cluster but isn't
managed by kix, it can be **imported** using `mkImport`. The imported instance
participates in DI resolution like any other instance — your package code
doesn't change at all. See the [Import Existing Resources](how-to/import-existing-resources.md)
guide for details.

---

## 10. Outputs: Exposing Values to Consumers

Use `outputs` on a resource to expose values that other packages might need:

```nix
service = scope.mkResource {
  apiVersion = "v1";
  kind = "Service";
  name = "${scope.instanceName}-postgres";
  outputs = {
    port = "5432";
    dbName = "mydb";
  };
  requires = [ self.statefulSet ];
  spec = {
    ports = [{ port = 5432; }];
    selector = scope.selectorLabels;
  };
};
```

Consumers access these via `.out`:

```nix
{ scope, config, lib, postgres }:
# ...
env = [
  { name = "DB_PORT"; value = postgres.out.port; }
  { name = "DB_NAME"; value = postgres.out.dbName; }
];
```

Each output value automatically carries the dependency context of the resource
it's defined on. Using `postgres.out.port` records a dependency on the postgres
Service.

The `.fqdn` attribute is generated automatically:
`<name>.<namespace>.svc.cluster.local` for namespaced resources.

---

## 11. Deploying Your Package in a Cluster

Once your package is written, deploy it through `buildCluster`:

```nix
# clusters/my-cluster.nix
{ kix, packages }:

kix.buildCluster {
  name = "my-cluster";
  modules = [{
    namespaces = {
      backend = { };
      data = { };
    };

    instances = {
      data = {
        postgres = {
          package = packages.postgres;
          aliases = [ "postgres" ];
          config = {
            storage = "100Gi";
            replicaCount = 3;
          };
        };
      };

      backend = {
        api = {
          package = packages.myApi;
          config = {
            image = "myregistry/api:v2.1.0";
            replicaCount = 5;
          };
        };
      };
    };
  }];
}
```

### Key cluster-level options

| Field | Purpose |
|---|---|
| `package` | The package function (imported from `packages/`) |
| `aliases` | DI resolution keys — other packages request these names |
| `config` | Passed as `config` to the build function, merged with option defaults |
| `deps` | Explicit DI overrides (keys are package function arg names) |
| `partsOverlays` | Override the inner fixpoint: `scope: self: base: { ... }` |

### Using `ref` for explicit cross-instance wiring

The `instances` function form receives `ref`, which is the cluster fixpoint.
You can use it to explicitly wire dependencies:

```nix
instances = { ref, ... }: {
  backend = {
    api = {
      package = packages.myApi;
      config = {
        # Explicit override: use the data namespace's postgres
        customDbHost = ref.data.postgres.fqdn;
      };
    };
  };
};
```

---

## 12. Migrating from Helm

### Quick bridge: `fromHelmChart`

If you have an existing Helm chart, you can import it directly:

```nix
# packages/my-chart.nix (or inline in cluster config)
kix.fromHelmChart {
  chart = ../charts/my-app;    # path to chart directory or .tgz
  values = {                    # base values (like values.yaml)
    replicaCount = 2;
    image.tag = "1.27-alpine";
  };
  releaseName = "my-app";
}
```

This runs `helm template` under the hood, wraps each output resource as a kix
resource via scope, and auto-selects a `root` (first Service, then Deployment,
then StatefulSet).

Override values at the cluster level:

```nix
instances = {
  my-namespace = {
    my-app = {
      package = kix.fromHelmChart { chart = ../charts/my-app; values = { ... }; };
      aliases = [ "my-app" ];
      config.values = { service.port = 8080; };  # deep-merged with package values
    };
  };
};
```

### Controlling the root resource

By default, `fromHelmChart` picks the first Service as `root`. Override with
`rootSelector`:

```nix
kix.fromHelmChart {
  chart = ../charts/my-app;
  rootSelector = { kind = "Service"; name = "my-app-web"; };
}
```

### When to go native

The Helm bridge is great for getting started, but you lose fine-grained
control. Consider converting to a native package when you need:

- **Custom outputs** — expose ports, database names, etc. to other packages
- **Cross-package dependencies** — use `postgres.fqdn` in your spec
- **Fine-grained `requires`** — control exactly what gets deployed
- **Conditional resources** — enable/disable parts based on config
- **The Merkle DAG** — automatic change propagation and `nix-diff` visibility

### Step-by-step migration

1. **Start with `fromHelmChart`** — get your chart deploying through kix
2. **Extract high-value resources** — convert the Service and Deployment to
   native `scope.mkResource` calls, keep the rest as helm resources
3. **Add outputs and dependencies** — wire in `fqdn`, `out`, and
   cross-package `${}` references
4. **Convert the rest** — move remaining resources to native definitions
5. **Drop the Helm bridge** — once everything is native

For each resource you convert, the pattern is:

```nix
# Helm YAML:
#   apiVersion: apps/v1
#   kind: Deployment
#   metadata:
#     name: my-app
#   spec:
#     template:
#       spec:
#         serviceAccountName: my-app-sa

# Native kix:
deployment = scope.mkResource {
  apiVersion = "apps/v1";
  kind = "Deployment";
  name = "${scope.instanceName}-my-app";
  spec.template.spec.serviceAccountName = "${self.serviceAccount}";
  # ...
};
```

The key change: hardcoded names become `${}` interpolations, which gives you
automatic dependency tracking.

---

## 13. Complete Worked Example

Here's a realistic package for a web application with all the patterns from
this guide:

```nix
# packages/webapp/default.nix
{ scope, lib, kix, postgres, redis, sessionStore ? redis }:

{
  meta = {
    version = "1.0.0";
    description = "Web application";
  };

  options = {
    image = lib.mkOption { type = lib.types.str; default = "myregistry/webapp:latest"; };
    replicaCount = lib.mkOption { type = lib.types.int; default = 2; };
    port = lib.mkOption { type = lib.types.int; default = 8080; };
    hpa = lib.mkOption {
      type = lib.types.anything;
      default = { enabled = false; minReplicas = 2; maxReplicas = 10; };
    };
    pdb = lib.mkOption {
      type = lib.types.anything;
      default = { enabled = false; };
    };
  };

  build = { self, config, clusterConfig }: {
    # ── Configuration ──────────────────────────────────────────
    configmap = scope.mkResource {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "${scope.instanceName}-webapp";
      data = {
        DATABASE_HOST = postgres.fqdn;
        DATABASE_PORT = postgres.out.port;
        CACHE_HOST = redis.fqdn;
        SESSION_HOST = sessionStore.fqdn;
      };
    };

    # ── RBAC ───────────────────────────────────────────────────
    serviceAccount = scope.mkResource {
      apiVersion = "v1";
      kind = "ServiceAccount";
      name = "${scope.instanceName}-webapp";
    };

    clusterRole = scope.mkClusterResource {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "ClusterRole";
      name = "${scope.instanceName}-webapp";
      extra.rules = [
        { apiGroups = [ "" ]; resources = [ "configmaps" ]; verbs = [ "get" "list" ]; }
      ];
    };

    clusterRoleBinding = scope.mkClusterResource {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "ClusterRoleBinding";
      name = "${scope.instanceName}-webapp";
      extra = {
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.clusterRole.out.name;
        };
        subjects = [{
          kind = "ServiceAccount";
          name = self.serviceAccount.out.name;
          namespace = scope.namespaceName;
        }];
      };
    };

    # ── Workload ───────────────────────────────────────────────
    deployment = scope.mkDeployment {
      name = "${scope.instanceName}-webapp";
      requires =
        lib.optional config.hpa.enabled self.hpa
        ++ lib.optional config.pdb.enabled self.pdb;
      spec = {
        replicas = if config.hpa.enabled then null else config.replicaCount;
        selector.matchLabels = scope.selectorLabels;
        template.spec = {
          serviceAccountName = self.serviceAccount.out.name;
          containers = [{
            name = "webapp";
            image = config.image;
            ports = [{ containerPort = config.port; }];
            envFrom = [{ configMapRef.name = "${self.configmap}"; }];
          }];
        };
      };
    };

    # ── Optional: HPA ──────────────────────────────────────────
    hpa = if config.hpa.enabled then scope.mkResource {
      apiVersion = "autoscaling/v2";
      kind = "HorizontalPodAutoscaler";
      name = "${scope.instanceName}-webapp";
      spec = {
        scaleTargetRef = {
          apiVersion = "apps/v1";
          kind = "Deployment";
          name = "${scope.instanceName}-webapp";
        };
        minReplicas = config.hpa.minReplicas;
        maxReplicas = config.hpa.maxReplicas;
      };
    } else null;

    # ── Optional: PDB ──────────────────────────────────────────
    pdb = if config.pdb.enabled then scope.mkResource {
      apiVersion = "policy/v1";
      kind = "PodDisruptionBudget";
      name = "${scope.instanceName}-webapp";
      spec = {
        selector.matchLabels = scope.selectorLabels;
        minAvailable = 1;
      };
    } else null;

    # ── Service ────────────────────────────────────────────────
    service = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "${scope.instanceName}-webapp";
      outputs = { port = toString config.port; };
      requires = [ self.deployment ];
      spec = {
        selector = scope.selectorLabels;
        ports = [{ port = config.port; targetPort = config.port; }];
      };
    };

    # ── Root ───────────────────────────────────────────────────
    root = self.service;
  };
}
```

### The resulting dependency graph

```
                              root
                                │
                            Service
                           (requires)
                                │
                           Deployment
                        ┌───────┼──────────┐
                     .out.name ${cm}    (optional)
                        │       │       HPA   PDB
                  ServiceAccount │
                    ↑            │
              (inverse dep)  ConfigMap ──${fqdn}──→ postgres, redis
                    │
            ClusterRoleBinding
                    │
               .out.name
                    │
              ClusterRole
```

The Service depends on the Deployment via `requires` (label selector relationships
need explicit tracking). The Deployment references the ServiceAccount and ConfigMap
via `.out.name` and `${}`. The ClusterRoleBinding references the ServiceAccount
(which is in the forward closure) so it's detected as an inverse dep. The
ClusterRoleBinding also references the ClusterRole, pulling it in as a forward
dep. Everything deploys correctly without manually listing RBAC in any `requires`.
