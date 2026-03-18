# Writing kix Package Definitions

This guide walks you through writing package definitions for kix, from first
principles to advanced patterns. If you're coming from Helm, there's a
dedicated migration section near the end — but reading the earlier sections
first will give you the mental model you need.

---

## 1. Your First Package

A kix package is a Nix function that returns a set of Kubernetes resources.
Here's the minimal shape:

```nix
{ scope, config, lib }:

let
  cfg = scope.defaults config {
    image = "nginx:1.27";
    replicaCount = 1;
  };
in
self: {

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-myapp";
    spec = {
      replicas = cfg.replicaCount;
      selector.matchLabels = { "app.kubernetes.io/name" = "myapp"; };
      template = {
        metadata.labels = { "app.kubernetes.io/name" = "myapp"; };
        spec.containers = [{
          name = "myapp";
          image = cfg.image;
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
      selector = { "app.kubernetes.io/name" = "myapp"; };
      ports = [{ port = 80; targetPort = 8080; }];
    };
  };

  main = self.service;
}
```

Three things to notice:

1. **The function signature** — `{ scope, config, lib }` gives you everything
   you need. `scope` provides resource constructors and instance metadata,
   `config` is user-provided configuration, `lib` is nixpkgs lib.

2. **`self`** — the second argument is a self-reference (a Nix fixpoint). You
   can reference any sibling attribute via `self.X`, in any order.

3. **`main`** — this is what consumers of your package see. When another
   package depends on yours, they get `main`'s `.fqdn` and `.out`.

### What `scope` gives you

| Attribute            | Purpose                                              |
|----------------------|------------------------------------------------------|
| `scope.mkResource`   | Create a namespaced K8s resource                     |
| `scope.mkClusterResource` | Create a cluster-scoped resource (no namespace) |
| `scope.instanceName` | The unique instance name (set by the cluster config) |
| `scope.namespaceName`| The namespace this instance lives in                 |
| `scope.namespace`    | The Namespace resource itself (for dependency tracking)|
| `scope.defaults`     | Merge user config with package defaults              |

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

The `self` parameter is a Nix fixpoint (`lib.fix`). Every attribute in your
package can reference any other attribute through `self`, regardless of
definition order:

```nix
self: {
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
}
```

Nix evaluates lazily, so circular *definitions* work as long as the actual
*values* aren't circular. A ClusterRoleBinding referencing a ServiceAccount
that doesn't reference the ClusterRoleBinding back is perfectly fine.

---

## 4. Setting Up `main`

`main` defines your package's public interface. It can be either a resource
directly or a `{ resource, requires }` attrset:

```nix
# Simple: main IS the resource
main = self.service;

# With requires: main exposes the service, but ensures the deployment is included
main = {
  resource = self.service;
  requires = [ self.deployment ];
};
```

### What goes in `main.requires`?

`main.requires` is for resources that are **top-level entry points** not
reachable from `main.resource` through interpolation or other `requires`
chains. In practice this is rare — it's mainly for packages that expose
**multiple independent services**:

```nix
# A package with two separate services (e.g., app + admin panel)
main = {
  resource = self.appService;
  requires = [ self.adminService ];
};
```

For the common case of a Service that selects a Deployment via labels, use
`scope.selectWorkload` to derive the selector labels from the target workload:

```nix
service = scope.mkResource {
  apiVersion = "v1";
  kind = "Service";
  name = "${scope.instanceName}-myapp";
  spec.selector = scope.selectWorkload self.deployment;  # derives matchLabels + tracks dependency
  spec.ports = [{ port = 80; }];
};

main = self.service;
```

`scope.selectWorkload target` reads `spec.selector.matchLabels` from the target
resource and returns the same labels with the target's store path attached as Nix
string context. This means:
- The selector labels are correct by construction (no shared variable to keep in sync)
- The dependency is tracked automatically (no `requires` needed)

It works with any resource that has `spec.selector.matchLabels` — Deployments,
StatefulSets, DaemonSets. Use it for Services, PDBs, etc.:

```nix
pdb = scope.mkResource {
  apiVersion = "policy/v1";
  kind = "PodDisruptionBudget";
  name = "${scope.instanceName}-myapp";
  spec.selector.matchLabels = scope.selectWorkload self.deployment;
  spec.minAvailable = 1;
};
```

For selecting a resource by its package-provided labels (e.g., a ServiceMonitor
matching a Service), use `scope.selectByLabels`:

```nix
serviceMonitor = scope.mkClusterResource {
  apiVersion = "monitoring.coreos.com/v1";
  kind = "ServiceMonitor";
  name = "${scope.instanceName}";
  spec.selector.matchLabels = scope.selectByLabels self.metricsService;
  spec.endpoints = [{ port = "metrics"; }];
};
```

If neither function applies (e.g., custom label subsets), fall back to explicit `requires`:

```nix
service = scope.mkResource {
  apiVersion = "v1";
  kind = "Service";
  name = "${scope.instanceName}-myapp";
  requires = [ self.deployment ];
  spec.selector = selectorLabels;
  spec.ports = [{ port = 80; }];
};
```

This is more precise. If one service depends on another within the same
package, you can express that directly:

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

main = self.appService;
# adminService is pulled in through appService's requires chain
```

### What consumers see

When another package depends on yours, they get the evaluated instance which
exposes:

- `.fqdn` — the DNS name of the main resource (e.g., `myapp.mynamespace.svc.cluster.local`)
- `.out` — named outputs (ports, database names, etc.)
- The full evaluated parts, if they need deeper access

---

## 5. Automatic Dependency Tracking (Forward Closure)

Starting from `main`, the system walks the dependency graph using BFS:

1. Look at the main resource's manifest — find all embedded store paths (from `${}` interpolations)
2. Follow each resource's `requires` list
3. Repeat for each discovered resource
4. Everything reachable is in the **forward closure** — these resources will be deployed

Example:

```
Service (main)
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
| Deployment → ServiceAccount (via `serviceAccountName`) | Yes, use `"${self.sa}"` | No |
| Deployment → ConfigMap (via volume mount name) | Yes, use `"${self.cm}"` | No |
| Service → Deployment (via label selector) | Use `scope.selectWorkload self.deployment` | No |
| PDB → Deployment (via label selector) | Use `scope.selectWorkload self.deployment` | No |
| HPA → Deployment (via `scaleTargetRef`) | No, name is a plain string | **Yes** |

The rule: **use `scope.selectWorkload` / `scope.selectByLabels` for label selector relationships. Use `requires`
for name-based references that don't support `${}` interpolation (e.g., HPA
`scaleTargetRef`).**

Place the `requires` on the resource that *needs* the other:

```nix
workload = scope.mkResource {
  apiVersion = "apps/v1";
  kind = "Deployment";
  name = "${scope.instanceName}-myapp";
  requires = [
    self.clusterRoleBinding   # RBAC must exist
  ]
  ++ lib.optional cfg.hpa.enabled self.hpa     # only if enabled
  ++ lib.optional pdbEnabled self.pdb;         # only if enabled
  spec = {
    template.spec.serviceAccountName = "${self.serviceAccount}";  # tracked by ${}
    # ...
  };
};
```

---

## 7. Inverse Dependencies

Here's where things get clever. Sometimes a resource isn't in the forward
closure (not reachable from `main`) but it **references** something that is.
The system detects this automatically and pulls it in as an **inverse
dependency**.

The classic example is RBAC:

```nix
self: {
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
        name = "${self.clusterRole}";       # references ClusterRole
      };
      subjects = [{
        kind = "ServiceAccount";
        name = "${self.serviceAccount}";     # references ServiceAccount
        namespace = scope.namespaceName;
      }];
    };
  };

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-myapp";
    spec.template.spec.serviceAccountName = "${self.serviceAccount}";
    # ...
  };

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${scope.instanceName}-myapp";
    spec.selector = scope.selectWorkload self.deployment;
    spec.ports = [{ port = 80; }];
  };

  main = self.service;
}
```

Here's how the system resolves this:

```
Forward closure (starting from Service):
  Service → (requires) → Deployment → (${}) → ServiceAccount
                                      (${}) → Namespace (via scope)

Not in forward closure:
  ClusterRoleBinding — BUT it references ServiceAccount (which IS in the closure)
  ClusterRole — no reference to anything in the closure

Inverse dependency detection:
  ClusterRoleBinding references ServiceAccount → pulled in as inverse dep

Now ClusterRoleBinding is in the closure, and IT references ClusterRole via ${} →
  ClusterRole gets pulled in as a forward dep of ClusterRoleBinding
```

**Result**: everything gets deployed, and you didn't need a single `requires`
for RBAC. The ClusterRoleBinding's `${}` references to the ServiceAccount are
enough for the system to figure it out.

### The general intuition

1. Add all your resources to `self`
2. Set `main` to whatever consumers connect to (usually a Service)
3. Add `requires` to your Service for resources selected by labels (like
   Deployments)
4. Use `${}` interpolation everywhere you can — Nix tracks it automatically
5. Resources that reference something in the closure get pulled in as inverse
   deps, and their own `${}` references pull in further resources

The full chain from the example:

```
Service ──requires──→ Deployment ──${}──→ SA ←──${}── CRB ──${}──→ ClusterRole
  │                                                    ↑
  main                                           (inverse dep:
                                                  references SA
                                                  which is in the
                                                  forward closure)
```

---

## 8. Optional and Conditional Resources

Use `if/then/else null` for resources that depend on configuration:

```nix
hpa = if cfg.hpa.enabled then scope.mkResource {
  apiVersion = "autoscaling/v2";
  kind = "HorizontalPodAutoscaler";
  name = "${scope.instanceName}-myapp";
  spec = {
    scaleTargetRef = {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "${scope.instanceName}-myapp";  # plain string — needs requires
    };
    minReplicas = cfg.hpa.minReplicas;
    maxReplicas = cfg.hpa.maxReplicas;
    metrics = cfg.hpa.metrics;
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
  ++ lib.optional cfg.hpa.enabled self.hpa
  ++ lib.optional pdbEnabled self.pdb;
  spec.replicas = if cfg.hpa.enabled then null else cfg.replicaCount;
};
```

---

## 9. Using Dependencies (Other Packages)

To depend on another package, add its package type as a function argument:

```nix
{ scope, config, lib, postgres }:

let cfg = scope.defaults config { ... };
in self: {

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-api";
    spec.template.spec.containers = [{
      name = "api";
      image = cfg.image;
      env = [
        { name = "DATABASE_HOST"; value = postgres.fqdn; }
        { name = "DATABASE_PORT"; value = postgres.out.port; }
      ];
    }];
  };

  # ...
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
{ scope, config, lib, redis, sessionStore ? redis, cache ? redis }:

self: {
  deployment = scope.mkResource {
    # ...
    spec.template.spec.containers = [{
      name = "myapp";
      image = cfg.image;
      env = [
        { name = "CACHE_HOST";   value = cache.fqdn; }
        { name = "SESSION_HOST"; value = sessionStore.fqdn; }
      ];
    }];
  };
  # ...
}
```

Here `redis` is a required dependency — it must exist in the cluster. But
`sessionStore` and `cache` are optional overrides: if the cluster has a
dedicated `sessionStore`-typed instance, it will be used for sessions;
otherwise it falls back to `redis`. Same for `cache`. This lets you start
simple (one Redis for everything) and split later without changing the package.

At the cluster level, you'd wire this up as:

```nix
# Simple: one redis for everything
instances = { ref, ... }: {
  backend = {
    redis = { package = packages.valkey; packageType = "redis"; };
    api   = { package = packages.myApi; packageType = "api"; };
  };
};

# Later: dedicated instances
instances = { ref, ... }: {
  backend = {
    redis        = { package = packages.valkey; packageType = "redis"; };
    session-store = { package = packages.valkey; packageType = "sessionStore"; };
    api          = { package = packages.myApi;  packageType = "api"; };
  };
};
```

In the second configuration, the `api` package automatically picks up
`session-store` for its `sessionStore` argument via DNS-like resolution (it
matches the packageType), while `cache` still falls back to `redis`.

### Dependency values carry context

When you use `postgres.fqdn` or `postgres.out.port`, those values carry the
store path context of the postgres package. This means Nix automatically
tracks your package as depending on postgres — no manual wiring needed.

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
  spec = {
    ports = [{ port = 5432; }];
    selector = scope.selectWorkload self.statefulSet;
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
  namespaces = {
    backend = { };
    data = { };
  };

  instances = { ref, ... }: {
    data = {
      postgres = {
        package = packages.postgres;
        packageType = "postgres";
        config = {
          storage = "100Gi";
          replicaCount = 3;
        };
      };
    };

    backend = {
      api = {
        package = packages.myApi;
        packageType = "api";
        config = {
          image = "myregistry/api:v2.1.0";
          replicaCount = 5;
        };
      };
    };
  };
}
```

### Key cluster-level options

| Field | Purpose |
|---|---|
| `package` | The package function (imported from `packages/`) |
| `packageType` | Used for dependency resolution — other packages request this name |
| `config` | Passed to the package as `config`, merged with `scope.defaults` |
| `aliases` | Additional names this instance can be resolved as |
| `parts` | Override the inner fixpoint: `self: super: { ... }` |

### Using `ref` for explicit cross-instance wiring

The `instances` function receives `ref`, which is the cluster fixpoint. You can
use it to explicitly wire dependencies:

```nix
instances = { ref, ... }: {
  backend = {
    api = {
      package = packages.myApi;
      packageType = "api";
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
resource via scope, and auto-selects a `main` (first Service, then Deployment,
then StatefulSet).

Override values at the cluster level:

```nix
instances = { ref, ... }: {
  my-namespace = {
    my-app = {
      package = kix.fromHelmChart { chart = ../charts/my-app; values = { ... }; };
      packageType = "my-app";
      config.values = { service.port = 8080; };  # deep-merged with package values
    };
  };
};
```

### Controlling the main resource

By default, `fromHelmChart` picks the first Service as `main`. Override with
`mainSelector`:

```nix
kix.fromHelmChart {
  chart = ../charts/my-app;
  mainSelector = { kind = "Service"; name = "my-app-web"; };
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
#
# A web application with:
# - Deployment + Service (core)
# - ServiceAccount + RBAC (inverse deps — auto-included)
# - ConfigMap (for app config)
# - Optional HPA and PDB

{ scope, config, lib, postgres, redis, sessionStore ? redis }:

let
  cfg = scope.defaults config {
    image = "myregistry/webapp:latest";
    replicaCount = 2;
    port = 8080;
    hpa = {
      enabled = false;
      minReplicas = 2;
      maxReplicas = 10;
    };
    pdb.enabled = false;
  };

  selectorLabels = {
    "app.kubernetes.io/name" = "webapp";
    "app.kubernetes.io/instance" = scope.instanceName;
  };

  labels = selectorLabels // {
    "app.kubernetes.io/managed-by" = "kix";
  };

in self: {

  # ── Configuration ──────────────────────────────────────────
  # ConfigMap with app settings. Interpolates dependency FQDNs,
  # so changes to postgres/redis propagate here automatically.

  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${scope.instanceName}-webapp";
    inherit labels;
    data = {
      DATABASE_HOST = postgres.fqdn;
      DATABASE_PORT = postgres.out.port;
      CACHE_HOST = redis.fqdn;
      SESSION_HOST = sessionStore.fqdn;
    };
  };

  # ── RBAC ───────────────────────────────────────────────────
  # ServiceAccount is referenced by the Deployment via ${}.
  # ClusterRole and ClusterRoleBinding are NOT referenced by the
  # Deployment — they'll be included as inverse dependencies
  # because the CRB references the ServiceAccount.

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-webapp";
    inherit labels;
  };

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-webapp";
    inherit labels;
    extra.rules = [
      { apiGroups = [ "" ]; resources = [ "configmaps" ]; verbs = [ "get" "list" ]; }
    ];
  };

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-webapp";
    inherit labels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.clusterRole}";         # tracked via ${}
      };
      subjects = [{
        kind = "ServiceAccount";
        name = "${self.serviceAccount}";       # tracked via ${}
        namespace = scope.namespaceName;
      }];
    };
  };

  # ── Workload ───────────────────────────────────────────────

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-webapp";
    inherit labels;
    requires =
      lib.optional cfg.hpa.enabled self.hpa
      ++ lib.optional cfg.pdb.enabled self.pdb;
    spec = {
      replicas = if cfg.hpa.enabled then null else cfg.replicaCount;
      selector.matchLabels = selectorLabels;
      template = {
        metadata.labels = labels;
        spec = {
          serviceAccountName = "${self.serviceAccount}";  # tracked via ${}
          containers = [{
            name = "webapp";
            image = cfg.image;
            ports = [{ containerPort = cfg.port; }];
            envFrom = [{ configMapRef.name = "${self.configmap}"; }];  # tracked via ${}
          }];
        };
      };
    };
  };

  # ── Optional: HPA ──────────────────────────────────────────

  hpa = if cfg.hpa.enabled then scope.mkResource {
    apiVersion = "autoscaling/v2";
    kind = "HorizontalPodAutoscaler";
    name = "${scope.instanceName}-webapp";
    inherit labels;
    spec = {
      scaleTargetRef = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${scope.instanceName}-webapp";
      };
      minReplicas = cfg.hpa.minReplicas;
      maxReplicas = cfg.hpa.maxReplicas;
    };
  } else null;

  # ── Optional: PDB ──────────────────────────────────────────

  pdb = if cfg.pdb.enabled then scope.mkResource {
    apiVersion = "policy/v1";
    kind = "PodDisruptionBudget";
    name = "${scope.instanceName}-webapp";
    inherit labels;
    spec = {
      selector.matchLabels = selectorLabels;
      minAvailable = 1;
    };
  } else null;

  # ── Service ────────────────────────────────────────────────

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${scope.instanceName}-webapp";
    inherit labels;
    outputs = { port = toString cfg.port; };
    spec = {
      selector = scope.selectWorkload self.deployment;
      ports = [{ port = cfg.port; targetPort = cfg.port; }];
    };
  };

  # ── Main ───────────────────────────────────────────────────
  # Service is the public entry point. The deployment is pulled in
  # via scope.selectWorkload (context tracking). RBAC is pulled in via inverse deps.

  main = self.service;
}
```

### The resulting dependency graph

```
                              main
                                │
                            Service
                        (scope.selectWorkload)
                                │
                           Deployment
                        ┌───────┼──────────┐
                      ${sa}   ${cm}     (optional)
                        │       │       HPA   PDB
                  ServiceAccount │
                    ↑            │
              (inverse dep)  ConfigMap ──${fqdn}──→ postgres, redis
                    │
            ClusterRoleBinding
                    │
               ${clusterRole}
                    │
              ClusterRole
```

The Service selects the Deployment via `scope.selectWorkload` (label selector + context tracking). The Deployment
interpolates the ServiceAccount and ConfigMap. The ClusterRoleBinding
references the ServiceAccount (which is in the forward closure) so it's
detected as an inverse dep. The ClusterRoleBinding also interpolates the
ClusterRole, pulling it in as a forward dep. Everything deploys correctly
without manually listing RBAC in any `requires`.
