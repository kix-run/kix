# kixpkgs v2: Unified Design RFC

## Working Document — March 2026

**Status:** Full v2 design — merges Merkle DAG, dependency injection, instance system, environments, and multi-team composition into one coherent spec.

**Supersedes:** `02_kixpkgs-design-doc_simplified.md` (v1), `00_v2_design_consolidated.md` (partial v2)
**Incorporates:** Discussion docs `01` through `07`, V1 docs `01`, `04`, `05`, `06`

---

## Guiding Principles

1. **Resources are derivations.** A K8s resource is a Nix store path. Its hash reflects its content and all its dependencies (the Merkle DAG). Native `${}` interpolation tracks dependencies automatically — no custom ref system needed.

2. **Packages are inner fixpoints.** A package is a self-referential set of resources. `self.configmap` gives you the final value. `overrideParts` swaps one resource; everything re-wires through the fixpoint.

3. **Instances are namespace-scoped.** The cluster is organized `{ namespace → { instance → package } }`. Two teams can both name an instance `cache` — as long as they're in different namespaces, there's no conflict. This mirrors how K8s itself scopes resources.

4. **Dependencies are injected.** Packages declare what they need as function arguments. The system resolves them DNS-style: same-namespace first, then cluster-wide. Users can override with explicit `ref` wiring when they want control.

5. **The system is Nix all the way down.** No module system, no `mkOption`, no YAML generation. Packages are functions, instances are attrsets, composition is `//`. You can inspect, override, and compose everything with standard Nix.

---

## Level 0 — mkResource: The Merkle DAG

A K8s resource is a Nix store path. Its hash is its identity.

### Signature

```nix
mkResource = {
  apiVersion,
  kind,
  name,
  namespace,          # a namespace resource, clusterScoped sentinel, or plain string
  spec ? {},
  data ? {},
  labels ? {},
  annotations ? {},
  outputs ? {},       # named values other resources can reference
  requires ? [],      # ordering deps — resources that must exist before this one
  extraDeps ? [],     # ordering-only deps, not in closure
  extra ? {},         # additional top-level fields (webhooks, subjects, etc.)
}:
```

### How it works

`builtins.toFile` creates a content-addressed store path from the **full manifest** of the resource. The manifest is serialized to JSON, which embeds store paths of all referenced resources via native `${}` interpolation. This is the Merkle DAG: change any input, and the hash changes.

```nix
let
  # Build the K8s manifest attrset.
  # Strings in spec/data may contain store paths of other resources
  # via ${self.configmap}, ${postgres.fqdn}, etc.
  manifest = {
    inherit apiVersion kind;
    metadata = { inherit name; }
      // lib.optionalAttrs (nsName != null) { namespace = nsName; }
      // lib.optionalAttrs (labels != {}) { inherit labels; }
      // lib.optionalAttrs (annotations != {}) { inherit annotations; };
  }
  // lib.optionalAttrs (spec != {}) { inherit spec; }
  // lib.optionalAttrs (data != {}) { inherit data; }
  // extra;

  manifestJson = builtins.toJSON manifest;

  # Content-addressed store path. The hash depends on:
  #   1. This resource's content (kind, name, spec, data, ...)
  #   2. All referenced resources (their store paths in manifestJson)
  _identityPath = builtins.toFile
    "k8s-${kind}-${nsKey}-${name}"
    manifestJson;

  # Attach this resource's store path context to a plain value
  attachCtx = value:
    builtins.appendContext (toString value) (builtins.getContext "${_identityPath}");

  self = {
    _type = "k8s-resource";
    inherit apiVersion kind name namespace requires extraDeps;

    # The store path. ${resource} → embeds this path, Nix tracks context.
    outPath = _identityPath;

    # FQDN — the DNS name consumers need. Carries this resource's context.
    fqdn = attachCtx "${name}.${nsKey}.svc.cluster.local";

    # Named outputs — each carries this resource's context.
    out = lib.mapAttrs (_: v: attachCtx (toString v)) outputs;

    # Raw manifest (with store paths, pre-post-processing).
    inherit manifest;
    rawManifest = manifest;

    # Registry entry: maps store path → resource metadata.
    registryEntry = {
      ${_identityPath} = { inherit apiVersion kind name namespace; resource = self; };
    };
  };
in self;
```

### What goes into the hash

| Included | Why |
|---|---|
| `apiVersion`, `kind`, `name`, `namespace` | Resource identity |
| `spec`, `data`, `labels`, `annotations`, `extra` | Resource content |
| Store paths of all referenced resources | Merkle DAG: change propagation |

| NOT included | Why |
|---|---|
| `requires`, `extraDeps` | Closure-level concern, not manifest content |
| `outputs` | Metadata about the resource, not part of K8s manifest |

### Why native `${}`

In v1, dependency tracking used custom ref attrsets and a tree walker (~165 lines). In v2, resources are derivations. `${self.configmap}` embeds the configmap's store path and Nix tracks the dependency in the string's context. No tree walker, no `scope.str [...]`, no forgetting to use `.ref`.

```nix
# v1: custom refs, easy to forget
configMap.name = self.configmap.ref;
value = scope.str [ "postgresql://" postgres.fqdn ":" postgres.out.port "/mydb" ];

# v2: native Nix, impossible to forget
configMap.name = "${self.configmap}";
value = "postgresql://${postgres.fqdn}:${postgres.out.port}/mydb";
```

### The three kinds of dependencies

**`deps` — Automatic, from `${}`.**
"I reference this resource by name in my spec." Inferred by `builtins.getContext` on the manifest JSON. Never declared manually.

**`requires` — Manual, inverted refs.**
"I need this to function, but *it* references *me*, not the other way around." SA → its bindings, Deployment → its PDB, CR → its CRD + controller. Flows transitively.

**`extraDeps` — Ordering only.**
"Deploy this before me, but don't include it in my closure." Rarely needed.

### The post-processor

Manifests contain store paths. Before serializing to YAML, the post-processor replaces them with K8s names using the cluster-wide registry:

```nix
postProcessManifest = registry: manifest:
  let
    json = builtins.toJSON manifest;
    ctx = builtins.getContext json;
    k8sPaths = builtins.filter (p: builtins.hasAttr p registry) (builtins.attrNames ctx);
    replaced = builtins.replaceStrings
      k8sPaths
      (map (p: registry.${p}.name) k8sPaths)
      json;
  in builtins.fromJSON (builtins.unsafeDiscardStringContext replaced);
```

### Namespace handling in mkResource

`namespace` can be:
- A **namespace resource** (derivation with `outPath`) — `scope.mkResource` injects this. Creates an automatic dependency via native `${}`.
- The **`clusterScoped` sentinel** — for ClusterRole, CRD, etc. Omits `metadata.namespace`.
- A **plain string** — for namespace-internal resources (policies inside `mkNamespace`).

```nix
clusterScoped = {
  _type = "k8s-cluster-scoped";
  __toString = _: "";
  name = null;
};
```

---

## Level 1 — Packages: The Inner Fixpoint

A package is a function that takes `{ scope, config, <dependencies...> }` and returns a self-referential set of resources.

### Package signature

```nix
# packages/coredns/default.nix
{ scope, config }:

self: {
  configmap = scope.mkResource { ... };
  workload = scope.mkResource { ... };
  service = scope.mkResource { ... };

  main = self.service // { requires = [ self.workload ]; };
}
```

The system wraps this in `lib.fix` internally. The package author just knows that `self.configmap` gives the final value.

### Package with dependencies (DI)

```nix
# packages/my-app/default.nix
{ scope, config, postgres, valkey }:

self: {
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = scope.instanceName;
    spec.template.spec.containers = [{
      name = "app";
      image = config.image;
      env = [
        {
          name = "DATABASE_URL";
          value = "postgresql://${postgres.fqdn}:${postgres.out.port}/mydb";
        }
        {
          name = "CACHE_URL";
          value = "redis://${valkey.fqdn}:${valkey.out.port}";
        }
      ];
    }];
  };

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = scope.instanceName;
    outputs = { port = "8080"; };
    spec.ports = [{ port = 8080; targetPort = 8080; }];
  };

  main = self.service // { requires = [ self.deployment ]; };
}
```

`postgres` and `valkey` are **dependency-injected** by the outer fixpoint. The package doesn't know or care where they come from. The system resolves them DNS-style (see Level 3).

### Default arguments as interface hints

```nix
{ scope, config, postgres, valkey, sessionStore ? valkey }:
```

This declares: "I need a `sessionStore`. If the cluster doesn't provide one, use whatever `valkey` resolved to." The resolution system tries to find a `sessionStore` first; if none exists, Nix's own `?` default fires and `sessionStore` equals the resolved `valkey`.

### Scope API

| Attribute | Description |
|---|---|
| `scope.instanceName` | The unique instance name from the cluster config |
| `scope.namespaceName` | The namespace name as a string |
| `scope.namespace` | The namespace resource (for explicit references) |
| `scope.mkResource { ... }` | Create a namespaced resource (namespace injected) |
| `scope.mkClusterResource { ... }` | Create a cluster-scoped resource |

```nix
mkScope = { instanceName, namespaceName, namespaceResource, clusterLabels }:
  {
    inherit instanceName namespaceName;
    namespace = namespaceResource;

    mkResource = { labels ? {}, ... }@args:
      k8s.mkResource (removeAttrs args [ "labels" ] // {
        namespace = namespaceResource;
        labels = clusterLabels // {
          "app.kubernetes.io/instance" = instanceName;
        } // labels;
      });

    mkClusterResource = { labels ? {}, ... }@args:
      k8s.mkResource (removeAttrs args [ "labels" ] // {
        namespace = clusterScoped;
        labels = clusterLabels // {
          "app.kubernetes.io/instance" = instanceName;
        } // labels;
      });
  };
```

### Config with defaults

Packages declare defaults with `scope.defaults` (a simple merge helper):

```nix
{ scope, config }:
let cfg = scope.defaults config {
  image = "registry.k8s.io/coredns/coredns:v1.11.1";
  replicas = 2;
}; in
self: { ... }
```

Unknown keys in user config optionally produce a warning.

### `main` and closure

Every package declares `main` — the resource other instances interact with. Typically a Service. `main` carries `requires` that pull in the workload and everything behind it:

```nix
main = self.service // { requires = [ self.workload self.configmap ]; };
```

The closure of `main` includes every resource transitively reachable via `deps` (from `getContext`) and `requires`. Deploy the closure → everything the instance needs is there, in the correct order.

### `overrideParts`

Swap one resource while inheriting the rest:

```nix
myCoredns = coredns.overrideParts (self: super: {
  workload = scope.mkResource {
    kind = "StatefulSet";
    spec.serviceName = "${self.service}";
    # RBAC, ConfigMap, PDB carry over from super via self
  };
});
```

### Package interface summary

```nix
instance = {
  # Resources (from inner fixpoint)
  configmap, deployment, service, ...

  # Public interface
  main         # the entry point resource
  fqdn         # main's FQDN (shortcut)
  out          # main's outputs (shortcut)
  closure      # all resources transitively from main

  # Override
  overrideParts  # self: super: { ... }

  # Metadata (from cluster config, not package)
  _meta = { instanceName, packageType, namespace, aliases; };
};
```

---

## Level 2 — Instances: The Outer Fixpoint

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
    data = {};
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
        };
        # postgres auto-resolved (unique cluster-wide)
        # OR explicit override:
        # postgres = ref.data.postgres;
      };

      worker = {
        package = packages.acme-worker;
        config = {
          database = ref.data.postgres;  # explicit ref in config
        };
      };
    };
  };
}
```

### Core design principles

**1. Instances are scoped by namespace.**
`production.api`, `data.postgres`, `kube-system.coredns`. Two teams can both define `cache` — different namespaces, no conflict.

**2. Dependencies are injected automatically.**
If `acme-api` takes `{ scope, config, postgres }:` as its function signature, the system resolves `postgres` to the instance with package type `postgres` — same-namespace first, then cluster-wide. No manual wiring needed for the common case.

**3. Explicit `ref` overrides always win.**
When the user writes `postgres = ref.data.postgres` in the instance config, that overrides auto-resolution. For sensitive services, set `autoResolve = false` to require all deps be wired explicitly.

**4. Namespaces are implied by usage.**
If you list instances under `production`, the namespace `production` exists. The separate `namespaces` block is for policy (quotas, network policies), not for declaring existence.

**5. Config is freeform but scoped.**
Each package defines what it expects. Each instance has its own config attrset. Cross-instance references live in the instance config, either via auto-resolution or explicit `ref`.

### The `ref` system

The `instances` attribute is a function that receives `{ ref, ... }`. `ref` is a lazy accessor into the namespace-nested fixpoint of all evaluated instances:

```nix
instances = { ref, ... }: {
  production = {
    api = {
      config = {
        database = ref.data.postgres;   # explicit: namespace.instance
      };
    };
  };
};
```

`ref.data.postgres` gives you the fully-evaluated postgres instance — its `main`, `fqdn`, `out`, `closure`. The fixpoint ties everything together.

### The nested fixpoint structure

The outer fixpoint is namespace-nested:

```nix
clusterInstances = lib.fix (self: {
  kube-system = {
    coredns = evaluateInstance { ... } self;
  };
  data = {
    postgres = evaluateInstance { ... } self;
  };
  production = {
    api = evaluateInstance { ... } self;
    worker = evaluateInstance { ... } self;
  };
});
```

Instance names are unique **within a namespace**, not cluster-wide. This mirrors K8s scoping. The DI resolution system builds an index across all namespaces (see Level 3).

### Instance-level overrides (parts)

For the case where config isn't enough — swap a resource inside a package:

```nix
instances = { ref, ... }: {
  kube-system = {
    coredns = {
      package = kixpkgs.packages.coredns;
      parts = self: super: {
        workload = self.scope.mkResource {
          apiVersion = "apps/v1";
          kind = "StatefulSet";
          name = "${self.scope.instanceName}-coredns";
          spec = {
            replicas = 3;
            serviceName = "${self.service}";
            selector.matchLabels = super.workload.spec.selector.matchLabels;
            template = super.workload.spec.template;
          };
        };
      };
    };
  };
};
```

### Error messages

```
error: instance 'api' in namespace 'production' references ref.data.redis,
       but no instance named 'redis' exists in namespace 'data'.
       Instances in 'data': postgres

error: ambiguous auto-resolution for 'postgres' requested by 'api' (ns: production):
       found in namespaces: data, analytics.
       Add explicit override: postgres = ref.data.postgres;

error: cycle detected in instance dependencies:
       production/api → data/postgres → production/api

error: instance 'postgres' in namespace 'data' is defined by both
       fragment 'backend-team' and fragment 'ml-team'.
```

---

## Level 3 — Dependency Injection and Resolution

### How `kixCallPackage` works

When evaluating an instance, the system introspects the package function's arguments, resolves each dependency, and calls the function:

```nix
kixCallPackage = { packageFn, instanceConfig, allInstances, resolutionIndex }:
  let
    fnArgs = builtins.functionArgs packageFn;
    systemArgs = [ "scope" "config" "lib" ];
    depArgNames = attrNames (removeAttrs fnArgs (genAttrs systemArgs (_: true)));

    # Which args have Nix-level defaults (? syntax)
    argHasDefault = filterAttrs (_: hasDefault: hasDefault) fnArgs;

    # Resolve each dependency
    resolvedDeps = foldl' (acc: argName:
      let
        # Explicit override in instance config always wins
        explicitOverride = instanceConfig.${argName} or null;
        resolution = resolveArg {
          inherit argName resolutionIndex explicitOverride;
          requesterNamespace = instanceConfig._namespace;
          hasDefault = argHasDefault ? ${argName} or false;
        };
      in if resolution.found
         then acc // { ${argName} = resolution.value; }
         else acc  # arg has Nix default, let it fall through
    ) {} depArgNames;

  in packageFn ({
    scope = mkScope instanceConfig;
    config = instanceConfig.config or {};
  } // resolvedDeps);
```

### Resolution algorithm: DNS-like

For each dependency argument, resolution follows this priority chain:

```
1. Explicit override in instance config         (user wired it via ref or inline)
2. Same-namespace match (package type or alias)  (DNS-local behavior)
3. Cluster-wide unique reachable match           (DNS-search behavior)
4. Nix function default (? syntax)               (package-level fallback)
5. Eval error                                    (missing dependency)
```

```nix
resolveArg = { argName, resolutionIndex, requesterNamespace, hasDefault, explicitOverride }:

  # 1. Explicit override
  if explicitOverride != null then
    { found = true; value = explicitOverride; }

  # 2. DNS-like resolution
  else let
    candidates = resolutionIndex.byKey.${argName} or [];
    sameNs = filter (c: c._meta.namespace == requesterNamespace) candidates;
    otherNs = filter (c: c._meta.namespace != requesterNamespace) candidates;
  in
    # Same namespace, exactly one → use it
    if length sameNs == 1 then
      { found = true; value = head sameNs; }

    # Same namespace, multiple → ambiguous
    else if length sameNs > 1 then
      throw "multiple '${argName}' in namespace ${requesterNamespace}"

    # No same-ns, one cluster-wide → use it
    else if sameNs == [] && length otherNs == 1 then
      { found = true; value = head otherNs; }

    # Multiple cluster-wide → ambiguous
    else if length otherNs > 1 then
      throw "multiple '${argName}' cluster-wide — specify explicitly"

    # No candidates, has default → let Nix handle it
    else if hasDefault then
      { found = false; }

    # No candidates, no default → error
    else throw "no '${argName}' found in cluster";
```

### The resolution index

Built once per fixpoint evaluation from all instances across all namespaces:

```nix
buildResolutionIndex = allInstances:
  let
    # Walk the nested { ns -> { name -> instance } } structure
    instances = concatMap (ns:
      map (name: allInstances.${ns}.${name})
        (attrNames allInstances.${ns})
    ) (attrNames allInstances);

    # Index by package type AND aliases
    indexEntries = concatMap (inst:
      let
        meta = inst._meta;
        keys = [ meta.packageType ] ++ meta.aliases;
      in map (key: { inherit key; instance = inst; }) keys
    ) instances;

    byKey = groupBy (e: e.key) indexEntries
            |> mapAttrs (_: map (e: e.instance));

  in { inherit byKey; };
```

### Aliases

Aliases are cluster-level metadata, not package-level. The same valkey package can be deployed as `cache` (no aliases, namespace-local) and as `session-valkey` (aliased as `sessionStore`, cluster-wide):

```nix
instances = { ref, ... }: {
  backend = {
    cache = {
      package = packages.valkey;
      # No aliases — namespace-local cache
    };
  };
  data = {
    session-valkey = {
      package = packages.valkey;
      aliases = [ "sessionStore" ];
      config.sentinel.enabled = true;
    };
  };
};
```

A package requesting `sessionStore` resolves to `session-valkey` (via alias). A package requesting `valkey` in namespace `backend` resolves to `cache` (same namespace, package type match).

### Resolution provenance

Every resolved dependency records how it was resolved, for debuggability:

```nix
_resolution = {
  postgres = { resolvedTo = "data/postgres"; rule = "cluster-wide-unique"; };
  valkey = { resolvedTo = "backend/cache"; rule = "same-namespace"; };
  sessionStore = { resolvedTo = "data/session-valkey"; rule = "cluster-wide-unique"; matchedVia = "alias"; };
};
```

### Resolution with nested fixpoint

The fixpoint is lazy. The resolution index accesses only `_meta` (from cluster config, static), not the inner fixpoint results (dynamic). No circular dependency:

```nix
clusterInstances = lib.fix (self:
  let
    resolutionIndex = buildResolutionIndex self;
    # ↑ Only touches _meta attributes — no inner fixpoint evaluation triggered
  in mapNamespaces (ns: mapAttrs (instanceName: instanceCfg:
    kixCallPackage {
      packageFn = loadPackage instanceCfg;
      instanceConfig = instanceCfg // { _namespace = ns; };
      allInstances = self;
      inherit resolutionIndex;
    }
  ))
);
```

---

## Level 4 — Namespaces

### Namespaces as resource packages

A namespace is a small inner fixpoint — the Namespace resource plus its policy resources:

```nix
mkNamespace = { name, labels ? {}, resourceQuota ? null, networkPolicies ? {} }:
  lib.fix (ns: {
    resource = mkResource {
      apiVersion = "v1";
      kind = "Namespace";
      inherit name;
      namespace = clusterScoped;
      labels = labels // { "kubernetes.io/metadata.name" = name; };
      requires =
        lib.optional (resourceQuota != null) ns.quota
        ++ builtins.attrValues ns.netpols;
    };

    quota = mkResource {
      apiVersion = "v1";
      kind = "ResourceQuota";
      name = "${name}-quota";
      namespace = name;  # plain string — internal to namespace package
      spec.hard = resourceQuota;
    };

    netpols = lib.mapAttrs (polName: pol:
      mkResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "NetworkPolicy";
        name = "${name}-${polName}";
        namespace = name;
        spec = pol;
      }
    ) networkPolicies;

    main = ns.resource;
    inherit name;
  });
```

Network policies are **named attrsets** (not lists) so multiple teams can merge policies without collision.

### Automatic namespace dependency

`scope.mkResource` injects the namespace resource. Every resource in a namespace automatically depends on its Namespace resource via native `${}` tracking. Deploy ordering is correct: Namespace first, then policies, then resources.

### Implicit namespace creation

If a namespace is referenced by an instance but has no `namespaces.*` entry, a bare namespace (no policies) is created automatically.

---

## Level 5 — Environments: `mkEnv`

### The problem

Teams run the same services in dev, staging, and prod with different configs. Copy-pasting instance blocks drifts.

### Instance sets

An instance set is a function `{ ref, env }: { ... }` that returns instances without namespace assignment:

```nix
appStack = { ref, env }: {
  api = {
    package = packages.acme-api;
    config = {
      image = env.config.apiImage or "api:latest";
    };
  };
  worker = {
    package = packages.acme-worker;
  };
};

dataStack = { ref, env }: {
  postgres = {
    package = packages.postgresql;
    config.storage = env.config.pgStorage or "10Gi";
  };
};
```

### `mkEnv`

Stamps instance sets into namespaces prefixed by environment name:

```nix
instances = { ref, ... }:
  # Shared infrastructure (not env-stamped)
  {
    kube-system.coredns = { package = kixpkgs.packages.coredns; };
  }
  # Dev: small
  // kixpkgs.mkEnv "dev" {
    config = { pgStorage = "10Gi"; };
  } {
    app = appStack;
    data = dataStack;
  }
  # Prod: big
  // kixpkgs.mkEnv "prod" {
    config = {
      pgStorage = "200Gi";
      apiImage = "myregistry.io/api:v2.1.0";
    };
  } {
    app = appStack;
    data = dataStack;
  };
```

### What `mkEnv` produces

For `mkEnv "dev" { ... } { app = appStack; data = dataStack; }`:

```
Namespaces created:        Instances created:
  dev-app                    dev-app/api
  dev-data                   dev-app/worker
                             dev-data/postgres
```

The namespace names are `${envName}-${setName}`. Refs within a set use env-prefixed namespaces. Refs to shared infrastructure (like `ref.kube-system.coredns`) work unchanged.

### Per-instance overrides within an env

```nix
// kixpkgs.mkEnv "prod" {
  config = { pgStorage = "200Gi"; };
  overrides = {
    app.api.parts = self: super: {
      # Add a sidecar to the prod API
    };
    data.postgres.config.backups = true;
  };
} { app = appStack; data = dataStack; }
```

### Environment-scoped resolution

When resolving deps for `dev-app/api`, the resolver prefers instances within the same `dev-*` environment scope. This prevents `dev-app/api` from accidentally resolving to `prod-data/postgres`:

```
1. Same namespace (dev-app)         → highest priority
2. Same env scope (dev-*)           → env-local resolution
3. Shared instances (no env prefix) → shared infra
4. Error                            → ambiguous or missing
```

This is implemented by tagging instances with `_envScope` during `mkEnv`.

### The mental model

```
                 ┌──────────────────────────┐
                 │   Instance Sets           │
                 │   (define once)           │
                 │                           │
                 │   appStack:               │
                 │     api, worker           │
                 │                           │
                 │   dataStack:              │
                 │     postgres              │
                 └───────────┬──────────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
         mkEnv "dev"    mkEnv "prod"   mkEnv "canary"
              │              │              │
              ▼              ▼              ▼
        dev-app/          prod-app/      canary-app/
          api               api            api
          worker             worker         worker
        dev-data/         prod-data/     canary-data/
          postgres          postgres       postgres
```

---

## Level 6 — Multi-Team Composition: Fragments

### Each team produces a fragment

```nix
# teams/platform/fragment.nix
{ packages }:
{
  namespaces = {
    kube-system = {};
    ingress = { resourceQuota.hard."requests.cpu" = "4"; };
  };

  instances = { ref, ... }: {
    kube-system = {
      coredns = { package = packages.coredns; };
    };
    ingress = {
      nginx-ingress = { package = packages.nginx-ingress; };
    };
  };
}
```

```nix
# teams/backend/fragment.nix
{ packages }:
{
  namespaces = {
    production = { labels."team" = "backend"; };
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
          # postgres auto-resolved
        };
      };
    };
  };
}
```

### `mergeFragments`

Combines fragments with collision detection:

```nix
mergeFragments = { fragments, namespacePolicies ? {} }:
  let
    # Instances: (namespace, instance) collision is an error
    mergedInstances = mergeInstancesWithCollisionCheck fragments;

    # Namespaces: deep merge with leaf-conflict errors
    mergedNamespaces = mergeNamespacesDeep fragments;

    # Platform-owned policies always override fragment-level policies
    finalNamespaces = applyPolicies mergedNamespaces namespacePolicies;

  in { namespaces = finalNamespaces; instances = mergedInstances; };
```

**Instances:** Two fragments defining the same instance name in the same namespace is an error. Different fragments defining `cache` in `backend` and `cache` in `ml` is fine — different namespaces.

**Namespaces:** Deep merge. Multiple fragments can contribute to the same namespace. Named network policies merge naturally. Leaf-field conflicts error.

**Cross-fragment references:** Work through DI auto-resolution or explicit `ref`. The merge makes it work. CI catches if someone removes an instance that others depend on.

### The assembly flake

```nix
{
  outputs = { self, kixpkgs, team-platform, team-backend, team-ml, ... }:
    let
      packages = kixpkgs.lib.mergeRegistries [
        kixpkgs.packages
        internal.packages
      ];

      fragments = [
        (team-platform.fragment { inherit packages; })
        (team-backend.fragment { inherit packages; })
        (team-ml.fragment { inherit packages; })
      ];

      namespacePolicies = {
        production.resourceQuota.hard = { "requests.cpu" = "20"; };
        data.networkPolicies.backend-only = { /* ... */ };
      };

    in {
      cluster = kixpkgs.lib.buildCluster (
        kixpkgs.lib.mergeFragments { inherit fragments namespacePolicies; }
      );

      # Per-team deploy targets
      deploy = {
        backend = self.cluster.deployGroup [
          "data/postgres"
          "production/api"
        ];
      };
    };
}
```

---

## CRDs and Type Providers

CRDs have no textual reference from CR to CRD — `${}`  tracking can't help. `requires` remains essential. Type providers inject it transparently.

### mkTypeProvider

```nix
mkTypeProvider = { crd, controller }:
  {
    inherit crd controller;
    mk = { name, namespace, spec, ... }@args:
      mkResource ({
        apiVersion = crd.apiVersion;
        kind = crd.kind;
        inherit name namespace spec;
        requires = (args.requires or []) ++ [ crd controller ];
      } // builtins.removeAttrs args [ "requires" ]);
  };
```

### CRD-providing package exposes type providers

```nix
# Inside cert-manager package
types = {
  certificate = mkTypeProvider {
    crd = self.crds.certificate;
    controller = self.controller;
  };
};
```

### Consumer uses type providers

```nix
{ scope, config, certManager }:
self: {
  certificate = certManager.types.certificate.mk {
    name = "${scope.instanceName}-tls";
    namespace = scope.namespace;
    spec.secretName = "${scope.instanceName}-tls-secret";
  };
}
```

The consumer doesn't know about CRDs or controllers. Deploy ordering falls out of the DAG: CRDs → controller → CRs.

---

## Cross-Cutting Concerns: Capabilities + Modules

Three decoupled pieces:

**Packages declare capabilities (plain data):**
```nix
capabilities.monitoring = {
  endpoints = [{ port = "metrics"; interval = "15s"; }];
  metricsService = self.service;
};
```

**Modules iterate instances, read capabilities, produce resources:**
```nix
apply = { instances, clusterConfig }:
  lib.mapAttrs (name: instance:
    let cap = instance.capabilities.monitoring or null;
    in if cap == null then {} else {
      serviceMonitor = builders.mkServiceMonitor { /* from cap */ };
      attachTo = cap.metricsService;
    }
  ) instances;
```

Module outputs are merged back via `requires`. The ServiceMonitor ends up in the closure without the package knowing it exists.

---

## Package Registries

### Structure

```
kixpkgs/
├── flake.nix
├── lib/
│   ├── k8s.nix          # mkResource, closure, post-processor
│   ├── eval.nix          # buildCluster, kixCallPackage, DI resolution
│   └── env.nix           # mkEnv
├── packages/
│   ├── coredns/default.nix
│   ├── postgresql/default.nix
│   └── ...
└── default.nix           # collects all packages
```

### External registries

Any flake that exports a `packages` attrset is a registry:

```nix
# Internal registry
outputs = { self, kixpkgs, ... }: {
  packages = {
    acme-api = import ./packages/acme-api;
    acme-worker = import ./packages/acme-worker;
  };
};
```

### Consuming multiple registries

```nix
packages = {
  inherit (kixpkgs.packages) coredns cert-manager;
  inherit (internal.packages) acme-api acme-worker;
  inherit (internal.packages) postgresql;  # internal fork
};
```

---

## Full Example: CoreDNS Package (v2)

```nix
# packages/coredns/default.nix
{ scope, config }:

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
};

in self: {

  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    data.Corefile = cfg.corefile;
  };

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    extra.rules = [
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
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.clusterRole}";
      };
      subjects = [{
        kind = "ServiceAccount";
        name = "${self.serviceAccount}";
        namespace = scope.namespaceName;
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
          serviceAccountName = "${self.serviceAccount}";
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
            volumeMounts = [{
              name = "config-volume";
              mountPath = "/etc/coredns";
              readOnly = true;
            }];
          }];
          volumes = [{
            name = "config-volume";
            configMap = {
              name = "${self.configmap}";
              items = [{ key = "Corefile"; path = "Corefile"; }];
            };
          }];
        };
      };
    };
  };

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${scope.instanceName}-coredns";
    inherit labels;
    outputs = {
      port = "53";
      metricsPort = "9153";
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

  main = self.service // {
    requires = [ self.workload ];
  };
}
```

---

## API Reference

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

### Instance config

```nix
{
  package = <package function>;     # required
  config = { ... };                 # optional, freeform, passed to package
  parts = self: super: { ... };     # optional, override individual resources
  aliases = [ "sessionStore" ];     # optional, discoverable names for DI
  autoResolve = true;               # optional, default true
  <depName> = <instance>;           # optional, explicit DI override
}
```

### `mkEnv`

```nix
mkEnv "<env-name>" {
  config = { ... };          # passed to instance sets as env.config
  overrides = {              # optional, per-set per-instance overrides
    <set>.<instance>.config.<key> = <value>;
    <set>.<instance>.parts = self: super: { ... };
  };
} {
  <set-name> = <instance-set-function>;
  ...
}
```

Produces nested namespace attrsets where namespaces are `"${envName}-${setName}"`.

### `mergeFragments`

```nix
mergeFragments {
  fragments = [ <fragment> ... ];
  namespacePolicies = { <ns> = { <policy> }; ... };    # optional
}
```

Returns `{ namespaces, instances }` suitable for `buildCluster`.

### Namespace policy config

```nix
{
  labels = { ... };
  annotations = { ... };
  resourceQuota = { hard = { ... }; };
  networkPolicies = {                          # named attrsets, not lists
    <policy-name> = { <NetworkPolicy spec> };
  };
}
```

### Package signature

```nix
{ scope, config, <dep1>, <dep2>, ... }:
self: {
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

`env.name` is the environment name, `env.config` is the env-level config.

---

## Closure and Deploy

### Closure computation

```nix
computeClosure = registry: root:
  let
    getDeps = resource:
      let
        ctx = builtins.getContext (builtins.toJSON resource.rawManifest);
        k8sPaths = builtins.filter (p: builtins.hasAttr p registry) (builtins.attrNames ctx);
      in map (p: registry.${p}.resource) k8sPaths;

    go = { seen, order, queue }:
      if queue == [] then order
      else let
        head = builtins.head queue;
        rest = builtins.tail queue;
        id = "${head.kind}/${head.name}@${head.namespace or "_cluster_"}";
      in
      if builtins.hasAttr id seen then
        go { inherit seen order; queue = rest; }
      else
        go {
          seen = seen // { ${id} = true; };
          order = order ++ [ head ];
          queue = rest ++ (getDeps head) ++ (head.requires or []);
        };
  in go { seen = {}; order = []; queue = [ root ]; };
```

### Deploy groups

```nix
deploy.backend = cluster.deployGroup [
  "data/postgres"
  "production/api"
];
```

A deploy group merges the closures of the listed instances and topo-sorts them. Transitive deps are included — if `api` depends on `coredns`, coredns is in the closure.

---

## Open Questions

### Reachability checking

NetworkPolicy analysis at eval time — checking whether the requesting namespace is allowed to reach the target namespace. Described in detail in the DI docs. Worth implementing but not blocking for v1 of v2.

### Interface/protocol matching

Matching on structural interfaces ("anything with `.fqdn` and `.out.port`") instead of string names. Worth exploring once the name-based system proves limiting.

### Resolution stability

Adding a second postgres to the cluster changes resolution for existing consumers. The evaluator should detect this and list affected instances. Important for safety, can be implemented as a warning layer.

### Secret management

References to external secrets (Vault, AWS SSM, sealed secrets) are represented as package config, not inlined values. The package produces ExternalSecret or SecretProviderClass resources. No secret values flow through Nix evaluation.

### `optionalInstances` (future: auto-install)

A pool of package instances that are available for DI but not included in the output closure unless actually referenced. Leverages the Merkle DAG: only store paths of actually-referenced services end up in the output. If the pool is empty, nothing auto-resolves. If it contains the whole registry, everything auto-resolves on demand. This is the natural successor to the auto-install design (V1 doc 05, approach D) but falls out almost trivially from the store-path-based architecture.
