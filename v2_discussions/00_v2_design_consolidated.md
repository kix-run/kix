# kixpkgs v2: Consolidated Design (Bottom-Up)

## Working Document — March 2026

**Status:** Bottom-up redesign — instances are packages, not config descriptions
**Predecessors:** Discussion docs `01` through `06`

---

## Guiding Principle

Every level of kixpkgs v2 works with **actual Nix packages** — derivations you can inspect, override, and compose. There is no separate "config description" format that gets interpreted into packages. An instance IS a package. A namespace IS a resource. The system is Nix all the way down.

---

## Level 0 — mkResource (the derivation)

A K8s resource is a Nix store path. Its hash is its identity.

### Signature

```nix
mkResource = {
  apiVersion,
  kind,
  name,
  namespace,          # a namespace resource (store path) or clusterScoped sentinel
  spec ? {},
  data ? {},
  labels ? {},
  annotations ? {},
  outputs ? {},       # named values other resources can reference
  requires ? [],      # ordering deps — resources that must exist before this one
}:
```

### How it works

`builtins.toFile` creates a content-addressed store path from the **full identity** of the resource: its manifest content AND its requires. This path IS the resource — its hash reflects everything about what it is and what it needs.

```nix
let
  manifest = {
    inherit apiVersion kind;
    metadata = { inherit name; }
      // lib.optionalAttrs (namespace ? outPath) { namespace = namespace.name; }
      // lib.optionalAttrs (labels != {}) { inherit labels; }
      // lib.optionalAttrs (annotations != {}) { inherit annotations; };
  }
  // lib.optionalAttrs (spec != {}) { inherit spec; }
  // lib.optionalAttrs (data != {}) { inherit data; };

  manifestJson = builtins.toJSON manifest;

  # The identity includes both the manifest and all requires.
  # requires store paths are embedded in the identity content,
  # so they affect the hash and appear in getContext.
  requiresPaths = map (r: "${r}") requires;
  identityContent = builtins.toJSON {
    manifest = manifest;
    requires = requiresPaths;
  };

  _identityPath = builtins.toFile "k8s-${kind}-${name}" identityContent;

  # Attach this resource's identity to a value so it carries the dep
  attachCtx = value:
    builtins.appendContext (toString value)
      (builtins.getContext "${_identityPath}");
in {
  _type = "k8s-resource";
  _args = args;               # preserved for withRequires to reconstruct
  inherit apiVersion kind name namespace requires;
  outPath = _identityPath;
  fqdn = attachCtx "${name}.${namespace.name}.svc.cluster.local";
  out = lib.mapAttrs (_: v: attachCtx (toString v)) outputs;
  rawManifest = manifest;
  registryEntry = { ${_identityPath} = { inherit apiVersion kind name namespace; }; };
}
```

### Why `requires` is in the hash

The Merkle DAG should represent the **complete deployment graph**, not just content dependencies. By including `requires` in the identity:

1. **The store IS the graph.** `nix-store --query --references` on any resource gives you its full dependency tree — both content deps (from `${}` interpolation) and ordering deps (from `requires`). No need to re-evaluate kix.

2. **No separate closure computation.** The BFS walk that `computeClosure` did in the old design is unnecessary. The Nix store already knows the graph. Walk store references to get the topological order.

3. **Self-describing artifacts.** Once resources are in the store, anyone (or any tool) can inspect the full deployment tree without access to the kix evaluator. The store paths are the source of truth.

4. **Identity is correct.** A Service that `requires` its Deployment IS a different deployment unit than the same Service without that requires. Different requires = different thing = different hash. This is honest.

### Native `${}` replaces `.ref`

In v1, cross-resource references needed a custom tracking layer:

```nix
# v1 — eliminated
value = k8s.str [ "postgresql://" postgres.fqdn ":" postgres.out.port "/mydb" ];
```

In v2, native Nix string interpolation does the tracking:

```nix
# v2 — just Nix
value = "postgresql://${postgres.service.fqdn}:${postgres.service.out.port}/mydb";
```

`${}` embeds the store path in the string context. `builtins.getContext` extracts it later. The entire `refs.nix` (~65 lines) and `resolve.nix` tree walker (~100 lines) are eliminated.

### Outputs carry context

Outputs are strings with the resource's store path attached via `appendContext`. When another resource interpolates `${postgres.out.port}`, it gets both the value ("5432") and the dependency (postgres's store path in the string context).

### The Merkle DAG

What's in the hash: apiVersion, kind, name, namespace, spec, data, labels, annotations, all referenced resources (embedded via `${}`), and all `requires` (embedded as store paths). Change a configmap → its store path changes → the deployment referencing it gets a new hash. Add a `requires` → the hash changes too. The full deployment graph is in the Merkle DAG.

What's NOT in the hash: `outputs` (metadata for consumers), `_type` (internal tag). These are attributes on the Nix attrset, not part of the store identity.

### `builtins.toFile` vs `derivation`

Start with `builtins.toFile` — lighter, pure content-addressing, no builder overhead. If we ever need to embed store paths from real Nix derivations (e.g., Nix-built container images), switch to `derivation {}`. The change is local to mkResource.

---

## Level 1 — mkPackage (inner fixpoint)

A package is a group of related K8s resources tied together with `lib.fix`.

### Structure

```nix
mkPackage = packageFn: args:
  let
    parts = lib.fix (packageFn args);
  in parts // {
    _type = "k8s-package";
    main = parts.main;
    out = parts.main.out;
    fqdn = parts.main.fqdn;
    registry = collectRegistryEntries parts;
    override = newArgs: mkPackage packageFn (args // newArgs);
    overrideParts = f:
      mkPackage (a: self:
        let base = packageFn a self;
        in base // (f self base)
      ) args;
  };
```

The inner fixpoint lets resources within a package reference each other:

```nix
# packages/postgres.nix
{ scope, config, ... }:

# This function returns a package — it IS the package constructor
mkPackage (args: self: {
  configmap = scope.mkResource {
    apiVersion = "v1"; kind = "ConfigMap";
    name = "${scope.instanceName}-config";
    data = {
      POSTGRES_DB = args.database or "app";
      MAX_CONNECTIONS = toString (args.maxConnections or 100);
    };
  };

  pvc = scope.mkResource {
    apiVersion = "v1"; kind = "PersistentVolumeClaim";
    name = "${scope.instanceName}-data";
    spec.resources.requests.storage = args.storage or "10Gi";
    spec.accessModes = [ "ReadWriteOnce" ];
  };

  deployment = scope.mkResource {
    apiVersion = "apps/v1"; kind = "Deployment";
    name = scope.instanceName;
    spec = {
      replicas = args.replicas or 1;
      template.spec.containers = [{
        name = "postgres";
        image = args.image or "postgres:16";
        envFrom = [{ configMapRef.name = "${self.configmap}"; }];
        volumeMounts = [{ name = "data"; mountPath = "/var/lib/postgresql/data"; }];
      }];
      template.spec.volumes = [{
        name = "data";
        persistentVolumeClaim.claimName = "${self.pvc}";
      }];
    };
  };

  service = scope.mkResource {
    apiVersion = "v1"; kind = "Service";
    name = scope.instanceName;
    spec.ports = [{ port = 5432; }];
    outputs.port = "5432";
    requires = [ self.deployment ];  # service needs deployment running
  };

  main = self.service;
})
```

Notice: `${self.configmap}` embeds the configmap's store path in the deployment spec. The dependency is tracked automatically. No `.ref`, no custom combinators.

### Override mechanisms

**`override`** — change the constructor arguments:

```nix
postgres.override { storage = "500Gi"; replicas = 3; }
```

**`overrideParts`** — reach into the fixpoint:

```nix
postgres.overrideParts (self: super: {
  deployment = super.deployment // {
    # add a sidecar, tweak resource limits, etc.
  };
})
```

Both return a new, real package. The result has `.override`, `.overrideParts`, `.closure`, `.fqdn` — everything the original had.

### `withRequires` — ordering dependencies

Sometimes resource A must exist before resource B, but B doesn't textually reference A (e.g., a CRD must exist before a CR that uses it, but the CR's spec doesn't contain the CRD's name).

```nix
withRequires = additionalRequires: resource:
  mkResource (resource._args // {
    requires = (resource._args.requires or []) ++ additionalRequires;
  });
```

This creates a **new derivation** — different hash, same K8s manifest content, but with additional store path references baked into its identity. This is correct: the resource with the requires IS a different deployment unit. Its store path now references the required resources, so walking the Nix store graph will find them.

### Per-package registry

Each package collects `registryEntry` from all its resources into a single `registry` attrset. This maps store paths → resource metadata (apiVersion, kind, name, namespace). Used later for closure computation and post-processing.

```nix
collectRegistryEntries = parts:
  lib.foldl' (acc: v:
    if v ? registryEntry then acc // v.registryEntry
    else acc
  ) {} (lib.attrValues parts);
```

---

## Level 2 — Instances

An instance is a package instantiated with specific config, in a specific namespace, with a specific scope. It IS a real package — you can call `.override`, `.overrideParts`, inspect `.closure`, reference `.fqdn`.

### What an instance is NOT

An instance is not a config description like:

```nix
# NOT this — this is a config blob, not a package
instances.postgres = {
  namespace = "data";
  storage = "100Gi";
};
```

### What an instance IS

An instance is the result of calling a package constructor:

```nix
# This IS the instance — a real evaluated package
postgres = callPackage ./packages/postgres.nix {
  storage = "100Gi";
};
```

The instance concept is about **naming and composition** — giving a package a home in the cluster fixpoint where it can be found by the DI system. It's not about a separate data format that gets "compiled" into packages.

### Instance identity

Every instance carries `_meta` — metadata that the resolution system uses to find it:

```nix
{
  _meta = {
    instanceName = "postgres";
    packageType = "postgres";      # which package constructor was used
    namespace = "data";
    aliases = [];                  # additional names this instance answers to
  };
}
```

`_meta` is computed from the cluster definition's static config, NOT from package evaluation. This is critical: the resolution index can be built without forcing any package's inner fixpoint, avoiding circular evaluation.

### Instance creation

Instances are created inside the cluster fixpoint (Level 4). The cluster definition specifies what to build; `callPackage` builds it:

```nix
# Inside the cluster fixpoint
postgres = self.callPackage ./packages/postgres.nix {
  storage = "100Gi";
};
```

The result is a real package with all the standard attributes:

```nix
postgres.main            # → the Service resource (derivation)
postgres.deployment      # → the Deployment resource
postgres.fqdn            # → "postgres.data.svc.cluster.local" (with context)
postgres.out.port        # → "5432" (with context)
postgres.override { }    # → new package
postgres.overrideParts f # → new package
postgres.registry        # → { "/nix/store/..." = { kind = "Service"; ... }; ... }
```

---

## Level 3 — callPackage + DNS-like DI Resolution

### callPackage

`callPackage` auto-injects dependencies by introspecting the package function's arguments:

```nix
callPackage = resolutionIndex: path: explicitArgs:
  let
    fn = import path;
    fnArgs = builtins.functionArgs fn;
    autoArgs = lib.mapAttrs (name: hasDefault:
      let resolved = resolveArg resolutionIndex name;
      in if explicitArgs ? ${name} then explicitArgs.${name}
         else if resolved.found then resolved.value
         else if hasDefault then resolved   # let Nix ? default fire
         else throw "Cannot resolve dependency '${name}': no match found"
    ) fnArgs;
  in fn (autoArgs // explicitArgs);
```

### DNS-like resolution

When a package declares `{ postgres, ... }:` as its arguments, the resolver determines WHICH postgres instance to inject. Resolution follows a priority chain — namespace-local first, then wider:

```
1. Explicit override in callPackage args     → use it
2. Same-namespace match (by packageType)     → use it (must be unique)
3. Same-namespace match (by alias)           → use it (must be unique)
4. Cluster-wide unique match                 → use it
5. Nix ? default in function signature       → let default fire
6. No match, no default                      → error
```

Ambiguity at any level is an error, not a silent choice.

### Resolution implementation

```nix
buildResolutionIndex = instances:
  # Build a multimap: name → [ { instance, namespace } ]
  lib.foldl' (acc: inst:
    let
      meta = inst._meta;
      names = [ meta.packageType ] ++ meta.aliases;
      addName = acc: n:
        acc // { ${n} = (acc.${n} or []) ++ [{ value = inst; namespace = meta.namespace; }]; };
    in lib.foldl' addName acc names
  ) {} (lib.attrValues instances);

resolveArg = index: callerNamespace: name:
  if !(index ? ${name}) then { found = false; }
  else
    let
      candidates = index.${name};
      sameNs = filter (c: c.namespace == callerNamespace) candidates;
    in
      if length sameNs == 1 then { found = true; value = (head sameNs).value; }
      else if length sameNs > 1 then throw "Ambiguous: multiple '${name}' in namespace '${callerNamespace}'"
      else if length candidates == 1 then { found = true; value = (head candidates).value; }
      else if length candidates > 1 then throw "Ambiguous: multiple '${name}' cluster-wide"
      else { found = false; };
```

### Resolution trace

For debuggability, resolution records its path:

```
resolving 'postgres' for instance 'api' (namespace: backend):
  1. explicit override?  no
  2. same-namespace?     no candidates in 'backend'
  3. cluster-wide?       1 candidate: postgres (namespace: data) ← selected
```

### The `? default` pattern

```nix
# Package signature
{ scope, postgres, valkey, sessionStore ? valkey }:
```

When `sessionStore` has no match in the resolution index, the resolver returns `{ found = false }`. Nix's own `?` mechanism fires and `sessionStore` gets bound to `valkey` (the already-resolved instance). No AST parsing, no special handling.

### Aliasing: two mechanisms

Both work, for different use cases:

**Fixpoint assignment** — direct, explicit:

```nix
# In the cluster fixpoint
sessionStore = self.valkey;
```

This creates a second name in the fixpoint pointing at the same package. Simple, visible in the attrset.

**Alias metadata** — for DI resolution:

```nix
# When creating the instance
valkey = self.callPackage ./packages/valkey.nix {
  _aliases = [ "sessionStore" "cache" ];
};
```

Aliases populate the resolution index so `callPackage` can find this instance by alternative names. The instance itself has one canonical name in the fixpoint.

Both approaches can coexist. Fixpoint assignment is better when you want a visible, auditable binding. Alias metadata is better when you want DI to discover the instance by role.

---

## Level 4 — Cluster Fixpoint (mkCluster)

### The outer fixpoint

The cluster is a single `lib.fix` over all instances:

```nix
mkCluster = { basePackages, overlays ? [] }:
  let
    applyOverlays = base: lib.foldl' (acc: ov: acc // (ov acc)) base overlays;

    cluster = lib.fix (self:
      let
        base = basePackages self;
        withOverlays = applyOverlays base;
        resolutionIndex = buildResolutionIndex withOverlays;
      in withOverlays // {
        callPackage = callPackage resolutionIndex;
        _registry = mergeRegistries withOverlays;
        # No _closure — the Nix store graph IS the closure.
        # Walk store references from any resource to get its full dep tree.
      }
    );
  in cluster;
```

### Cluster definitions are functions

Teams provide `self: { ... }` functions, not plain attrsets. This is the key difference from the previous design: the `self` parameter gives every definition access to the full cluster fixpoint, enabling cross-references between packages.

```nix
# teams/backend.nix
self: {
  api = self.callPackage ./packages/api.nix {
    replicas = 3;
  };

  postgres = self.callPackage ./packages/postgres.nix {
    storage = "100Gi";
  };
}
```

Because `self` is the fixpoint, `callPackage` has access to all instances and can resolve dependencies.

### Overlays

Overlays are `self: super: { ... }` — they compose over actual packages:

```nix
# overlays/prod-hardening.nix
self: super: {
  postgres = super.postgres.override { storage = "500Gi"; replicas = 3; };
  api = super.api.override { replicas = 5; };
}
```

This is real package composition. `super.postgres` is an actual package. `.override` returns an actual package. No config-blob merging, no `recursiveUpdate` on descriptions.

### Composing multiple teams

```nix
mkCluster {
  basePackages = self:
    (import ./teams/backend.nix self)
    // (import ./teams/frontend.nix self)
    // (import ./teams/platform.nix self);

  overlays = [
    (import ./overlays/prod-hardening.nix)
  ];
}
```

Instance name collision between teams is a Nix-level error (duplicate attrset keys) — no custom collision detection needed.

### Registry

The registry maps store paths → resource metadata (apiVersion, kind, name, namespace). It's needed for two things: post-processing (replacing store paths with K8s names in manifests) and human-readable introspection.

```nix
mergeRegistries = instances:
  lib.foldl' (acc: inst:
    if inst ? registry then acc // inst.registry else acc
  ) {} (lib.attrValues instances);
```

### Closure: just walk the store

There is no `computeClosure` function. The Nix store IS the dependency graph. Every resource's store path references its dependencies — both content deps (from `${}`) and ordering deps (from `requires`). To get the deployment order:

```nix
# Conceptual — this is what a deploy tool does:
# 1. Start from a resource's store path
# 2. nix-store --query --references gives you its direct deps
# 3. Recurse to get the full tree
# 4. Topological sort = deploy order
#
# No kix re-evaluation needed. The store is self-describing.
```

Within the Nix evaluator, `builtins.getContext` on the identity content gives the same information:

```nix
getDeps = resource:
  let ctx = builtins.getContext "${resource}";
  in filter (p: registry ? ${p}) (attrNames ctx);
```

But the key insight is that you **don't need kix** to walk the graph. Any tool that can read the Nix store can reconstruct the full deployment tree.

### Post-processor

Store paths in manifests get replaced with K8s resource names before serialization:

```nix
postProcessManifest = registry: manifest:
  let
    json = builtins.toJSON manifest;
    ctx = builtins.getContext json;
    k8sPaths = filter (p: registry ? ${p}) (attrNames ctx);
    replaced = builtins.replaceStrings
      k8sPaths
      (map (p: registry.${p}.name) k8sPaths)
      json;
  in builtins.fromJSON (builtins.unsafeDiscardStringContext replaced);
```

The post-processor runs at serialization time. It's the bridge between Nix's world (store paths) and Kubernetes' world (resource names). Note that `requires` store paths appear in the identity content but NOT in the K8s manifest — the post-processor only touches manifest fields.

---

## Level 5 — Scope + Namespace-as-Resource

### Namespace is a resource

A namespace is a derivation in the DAG, not a plain string. It participates in dependency tracking: any resource in a namespace implicitly depends on the namespace resource existing.

```nix
mkNamespace = { name, labels ? {}, resourceQuota ? null, networkPolicies ? {} }:
  lib.fix (ns: {
    resource = mkResource {
      apiVersion = "v1"; kind = "Namespace";
      inherit name;
      namespace = clusterScoped;
      labels = labels // { "kubernetes.io/metadata.name" = name; };
      requires = lib.optional (resourceQuota != null) ns.quota
                 ++ lib.attrValues ns.netpols;
    };

    quota = lib.optionalAttrs (resourceQuota != null) (mkResource {
      apiVersion = "v1"; kind = "ResourceQuota";
      name = "${name}-quota";
      namespace = name;  # plain string — bootstrap, not circular
      spec.hard = resourceQuota;
    });

    netpols = lib.mapAttrs (polName: polSpec: mkResource {
      apiVersion = "networking.k8s.io/v1"; kind = "NetworkPolicy";
      name = polName;
      namespace = name;  # plain string — bootstrap
      spec = polSpec;
    }) networkPolicies;

    main = ns.resource;
    inherit name;
    outPath = ns.resource.outPath;
  });
```

Policy resources (quotas, network policies) use the namespace name as a plain string internally. They don't go through scope — they're internal to the namespace package. This avoids the bootstrap circularity.

### `clusterScoped` sentinel

```nix
clusterScoped = {
  _type = "k8s-cluster-scoped";
  name = null;
  __toString = _: "";
};
```

Used for CRDs, ClusterRoles, PersistentVolumes, and the Namespace resource itself.

### Scope

Scope is created per-instance and injected via callPackage. It pre-binds namespace and cluster labels so packages never handle them directly:

```nix
mkScope = { instanceName, namespaceName, namespaceResource, clusterLabels }:
  {
    inherit instanceName namespaceName;
    namespace = namespaceResource;

    mkResource = { labels ? {}, ... }@args:
      k8s.mkResource (args // {
        namespace = namespaceResource;
        labels = clusterLabels
          // { "app.kubernetes.io/instance" = instanceName; }
          // labels;
      });

    mkClusterResource = { labels ? {}, ... }@args:
      k8s.mkResource (args // {
        namespace = clusterScoped;
        labels = clusterLabels
          // { "app.kubernetes.io/instance" = instanceName; }
          // labels;
      });
  };
```

When a package uses `scope.mkResource`, the namespace resource's store path is embedded in every resource it creates. The dependency is automatic.

### Cross-namespace references

```nix
# Same namespace — short name via store path (post-processed)
env.DB_HOST = "${postgres.service}";
# → "postgres" (after post-processing replaces store path with name)

# Cross namespace — FQDN (already contains the right value)
env.DB_HOST = "${postgres.service.fqdn}";
# → "postgres.data.svc.cluster.local"
```

FQDNs contain the namespace name as a literal string. The namespace dep is transitive: the service resource already depends on its namespace via scope.

### Namespace creation in the cluster

Namespaces are created in the cluster fixpoint and made available for scope construction:

```nix
basePackages = self: let
  namespaces = {
    backend = mkNamespace { name = "backend"; };
    data = mkNamespace {
      name = "data";
      resourceQuota.hard."requests.storage" = "500Gi";
    };
  };
in {
  # ... instances with scopes bound to these namespaces
};
```

Multiple instances sharing a namespace all reference the same namespace derivation — deduplication is automatic.

---

## Level 6 — CRDs + Type Providers

### The CRD gap

CRs (Custom Resources) never textually reference their CRD. A Certificate doesn't contain the string "certificates.cert-manager.io" in its spec. So `${}` can't establish this dependency automatically. `requires` adds it explicitly — the CRD and controller store paths are baked into the CR's identity, making the dependency visible in the store graph. Type providers automate this so consumers don't think about it.

### `mkTypeProvider`

```nix
mkTypeProvider = { crd, controller }:
  {
    mk = { name, namespace, spec, ... }@args:
      mkResource ({
        apiVersion = crd.apiVersion;
        kind = crd.kind;
        inherit name namespace spec;
        requires = (args.requires or []) ++ [ crd controller ];
      } // removeAttrs args [ "requires" ]);
  };
```

Every resource created through a type provider automatically depends on the CRD and controller. The consumer doesn't know or care.

### CRD-providing package

```nix
# packages/cert-manager.nix
{ scope, config, ... }:

mkPackage (args: self: {
  crds = {
    certificate = scope.mkClusterResource {
      apiVersion = "apiextensions.k8s.io/v1";
      kind = "CustomResourceDefinition";
      name = "certificates.cert-manager.io";
      spec = { ... };
    };
    issuer = scope.mkClusterResource { ... };
  };

  controller = scope.mkResource {
    apiVersion = "apps/v1"; kind = "Deployment";
    name = "cert-manager";
    spec = { ... };
    requires = lib.attrValues self.crds;
  };

  webhook = scope.mkResource { ... };

  types = {
    certificate = mkTypeProvider {
      crd = self.crds.certificate;
      controller = self.controller;
    };
    issuer = mkTypeProvider {
      crd = self.crds.issuer;
      controller = self.controller;
    };
  };

  main = withRequires [ self.controller self.webhook ] self.service;
})
```

### Consumer usage

```nix
{ scope, certManager, ... }:

mkPackage (args: self: {
  certificate = certManager.types.certificate.mk {
    name = "${scope.instanceName}-tls";
    namespace = scope.namespace;
    spec.secretName = "${scope.instanceName}-tls-secret";
  };

  # Consumer doesn't think about CRDs or controllers.
  # The type provider handles the requires chain.
})
```

### Shared CRDs

Two packages using the same cert-manager instance get the same CRD derivations — same store paths. Deduplication is automatic. If two different cert-manager instances define the same CRD name, it's detected at eval time as a store path collision in the registry.

### `overrideParts` works naturally

Override the controller → type providers automatically reference the new controller (inner fixpoint re-evaluates). Override a CRD → everything downstream picks up the change. The fixpoint property guarantees consistency.

---

## Level 7 — DX: Team Composition + Multi-Deploy

### Two composition models

Both are kept open. The choice depends on team structure and preference.

#### Self-functions

Each team produces a `self: { ... }` function. Teams are merged in one fixpoint:

```nix
# teams/backend.nix
self: {
  api = self.callPackage ./packages/api.nix { replicas = 3; };
  postgres = self.callPackage ./packages/postgres.nix { storage = "100Gi"; };
  valkey = self.callPackage ./packages/valkey.nix { _aliases = [ "sessionStore" ]; };
}
```

```nix
# cluster.nix
mkCluster {
  basePackages = self:
    (import ./teams/backend.nix self)
    // (import ./teams/frontend.nix self)
    // (import ./teams/platform.nix self);
}
```

Pros: Simple, all instances visible at one level, easy to reason about.
Cons: Name collisions between teams are only caught at eval time.

#### Overlays

Teams as `self: super: { ... }`, composed via overlay application:

```nix
mkCluster {
  basePackages = self:
    import ./teams/platform.nix self;  # base layer

  overlays = [
    (import ./teams/backend.nix)   # self: super: { ... }
    (import ./teams/frontend.nix)
  ];
}
```

Pros: Explicit layering, teams can reference and override instances from lower layers.
Cons: Order matters, more complex mental model.

Both produce actual packages. The choice is about team workflow, not about the package model.

### DX helpers

Helpers operate on real packages via `.override`:

```nix
# Place a set of instances into a namespace
inNamespace = ns: instances:
  lib.mapAttrs (_: inst:
    inst.override { _namespace = ns; }
  ) instances;
```

```nix
# Prefix instance names and namespaces for environment isolation
prefixEnv = prefix: instances:
  lib.mapAttrs (name: inst:
    inst.override {
      _instanceName = "${prefix}-${name}";
      _namespace = "${prefix}-${inst._meta.namespace}";
      _envScope = prefix;
    }
  ) instances;
```

These are thin wrappers around `.override` on real packages.

### Team file example

```nix
# teams/backend.nix
self: let
  inNs = inNamespace;
in
  inNs "backend" {
    api = self.callPackage ./packages/api.nix {
      image = "api:v1.5.0";
      replicas = 3;
    };
    worker = self.callPackage ./packages/worker.nix {
      image = "worker:v1.5.0";
      replicas = 2;
    };
  }
  // inNs "data" {
    postgres = self.callPackage ./packages/postgres.nix {
      storage = "100Gi";
    };
    valkey = self.callPackage ./packages/valkey.nix {
      _aliases = [ "sessionStore" "cache" ];
    };
  }
```

### Multi-deploy

`prefixEnv` creates real instances with prefixed namespaces. Environment-scoped resolution ensures `dev-api` finds `dev-postgres`, not `prod-postgres`.

```nix
# clusters/shared.nix
{ self }:
let
  base = import ./teams/backend.nix self;
  devOverrides = {
    postgres = { storage = "10Gi"; replicas = 1; };
    api = { replicas = 1; };
  };
  prodOverrides = {
    postgres = { storage = "500Gi"; replicas = 3; };
    api = { replicas = 5; };
  };
  withOverrides = packages: overrides:
    lib.mapAttrs (name: pkg:
      if overrides ? ${name} then pkg.override overrides.${name} else pkg
    ) packages;
in
  prefixEnv "dev" (withOverrides base devOverrides)
  // prefixEnv "prod" (withOverrides base prodOverrides)
```

Result: `dev-api` in namespace `dev-backend`, `prod-postgres` in namespace `prod-data`. Each environment is fully isolated.

### Environment-scoped resolution

`prefixEnv` adds `_envScope = prefix` to each instance's `_meta`. Resolution for `dev-api` requesting `postgres`:

```
1. Same namespace (dev-backend)?     No postgres there.
2. Same env scope (dev-*)?           dev-postgres! Use it.
3. Cluster-wide (unprefixed only)?   Shared services.
```

Cross-environment references require explicit wiring — you can't accidentally depend on prod-postgres from dev-api.

### Environment overrides

Because instances are real packages, environment-specific config is just `.override`:

```nix
# envs/dev.nix — applied via withOverrides
{
  postgres = { storage = "10Gi"; replicas = 1; };
  api = { replicas = 1; logLevel = "debug"; };
}
```

No separate "config" format, no special merging rules. It's Nix attrsets passed to `.override`.

---

## Level 8 — Flakes: Cross-Repo Composition

### kixpkgs as a flake

kixpkgs itself is the foundation flake — analogous to nixpkgs. It exports the library, reusable package constructors, and optionally pre-built fragments:

```nix
# kixpkgs/flake.nix
{
  outputs = { self }: {
    lib = {
      mkCluster = ...;
      mkResource = ...;
      mkPackage = ...;
      mkScope = ...;
      mkTypeProvider = ...;
      inNamespace = ...;
      prefixEnv = ...;
    };

    # Reusable package constructors — files that callPackage can call
    packages = {
      postgres = ./packages/postgres.nix;
      valkey = ./packages/valkey.nix;
      cert-manager = ./packages/cert-manager.nix;
      nginx-ingress = ./packages/nginx-ingress.nix;
    };

    # Pre-composed fragments for common stacks
    fragments = {
      monitoring = import ./fragments/monitoring.nix;
      ingress = import ./fragments/ingress.nix;
    };
  };
}
```

### Flake output schema

Three output types, mirroring nixpkgs conventions:

| Output | Shape | Analogous to |
|---|---|---|
| `kixPackages` | `{ name = ./path.nix; }` | nixpkgs `packages` — callPackage-able constructors |
| `kixFragments` | `{ name = self: { ... }; }` | nixpkgs `overlays` (but self-functions, not self/super) |
| `kixOverlays` | `{ name = self: super: { ... }; }` | nixpkgs `overlays` — modify existing instances |
| `kixClusters` | `{ name = <evaluated cluster>; }` | The final product — fully evaluated, deployable |

### Team as a flake

A team owns a repo. Their flake exports fragments and/or overlays:

```nix
# github:myorg/team-backend/flake.nix
{
  inputs.kixpkgs.url = "github:myorg/kixpkgs";

  outputs = { self, kixpkgs }: {
    kixFragments.default = clusterSelf:
      kixpkgs.lib.inNamespace "backend" {
        api = clusterSelf.callPackage ./packages/api.nix {
          image = "api:v1.5.0";
        };
        worker = clusterSelf.callPackage ./packages/worker.nix {};
      }
      // kixpkgs.lib.inNamespace "data" {
        postgres = clusterSelf.callPackage kixpkgs.packages.postgres {
          storage = "100Gi";
        };
        valkey = clusterSelf.callPackage kixpkgs.packages.valkey {
          _aliases = [ "sessionStore" ];
        };
      };

    # Team-specific packages not in kixpkgs
    kixPackages = {
      api = ./packages/api.nix;
      worker = ./packages/worker.nix;
    };
  };
}
```

The team uses `kixpkgs.packages.postgres` — a shared package constructor from the kixpkgs flake. Their own `api` and `worker` packages live in their repo. Both are real packages, both go through `callPackage`.

### Shared infrastructure as a flake

A monitoring stack, an ingress setup, a service mesh — these are reusable fragments:

```nix
# github:myorg/kix-monitoring/flake.nix
{
  inputs.kixpkgs.url = "github:myorg/kixpkgs";

  outputs = { self, kixpkgs }: {
    kixFragments.default = clusterSelf:
      kixpkgs.lib.inNamespace "monitoring" {
        prometheus = clusterSelf.callPackage ./packages/prometheus.nix {};
        grafana = clusterSelf.callPackage ./packages/grafana.nix {};
        alertmanager = clusterSelf.callPackage ./packages/alertmanager.nix {};
      };

    # Overlay that auto-wires monitoring into existing instances
    kixOverlays.scrape-targets = clusterSelf: super:
      let
        # Find all instances that expose metrics
        scrapeable = lib.filterAttrs
          (_: inst: inst ? out && inst.out ? metricsPort)
          super;
      in {
        prometheus = super.prometheus.override {
          scrapeTargets = scrapeable;
        };
      };
  };
}
```

The overlay pattern is powerful here: `scrape-targets` can introspect the cluster fixpoint (`super`) to auto-discover instances. It works because overlays run inside the fixpoint — `super` is the real, evaluated set of instances.

### Cluster flake — the composition point

The cluster flake is where everything comes together. It imports teams, shared stacks, and environment-specific overlays:

```nix
# github:myorg/clusters/flake.nix
{
  inputs = {
    kixpkgs.url = "github:myorg/kixpkgs";
    team-backend.url = "github:myorg/team-backend";
    team-frontend.url = "github:myorg/team-frontend";
    monitoring.url = "github:myorg/kix-monitoring";
  };

  outputs = { self, kixpkgs, team-backend, team-frontend, monitoring }: {
    kixClusters = {
      production = kixpkgs.lib.mkCluster {
        basePackages = clusterSelf:
          (team-backend.kixFragments.default clusterSelf)
          // (team-frontend.kixFragments.default clusterSelf)
          // (monitoring.kixFragments.default clusterSelf);

        overlays = [
          monitoring.kixOverlays.scrape-targets
          (import ./overlays/prod-hardening.nix)
        ];
      };

      staging = kixpkgs.lib.mkCluster {
        basePackages = clusterSelf:
          (team-backend.kixFragments.default clusterSelf)
          // (team-frontend.kixFragments.default clusterSelf)
          // (monitoring.kixFragments.default clusterSelf);

        overlays = [
          monitoring.kixOverlays.scrape-targets
          (import ./overlays/staging-config.nix)
        ];
      };
    };
  };
}
```

### Multi-deploy across clusters

`prefixEnv` composes naturally with flakes. A single cluster flake can produce dev+prod in one cluster, or separate clusters:

```nix
# Same cluster, isolated environments
kixClusters.shared = kixpkgs.lib.mkCluster {
  basePackages = clusterSelf: let
    base = team-backend.kixFragments.default clusterSelf;
  in
    kixpkgs.lib.prefixEnv "dev" (withOverrides base devConfig)
    // kixpkgs.lib.prefixEnv "prod" (withOverrides base prodConfig);
};

# Separate clusters, same base
kixClusters.dev = kixpkgs.lib.mkCluster {
  basePackages = clusterSelf:
    withOverrides (team-backend.kixFragments.default clusterSelf) devConfig;
};
kixClusters.prod = kixpkgs.lib.mkCluster {
  basePackages = clusterSelf:
    withOverrides (team-backend.kixFragments.default clusterSelf) prodConfig;
};
```

### Why you never merge evaluated clusters

Two evaluated clusters each have their own fixpoint with their own resolution index. Merging them would mean:
- Resolution breaks: instance A in cluster 1 was resolved against cluster 1's instances. Dropping it into cluster 2's namespace changes what its deps point to.
- Store paths are final: the hashes already encode the full dependency tree. You can't graft one tree into another.

Composition happens BEFORE fixpoint evaluation — that's what fragments and overlays are for. A "cluster merge" is really "compose two fragments into one fixpoint":

```nix
# NOT: merge cluster-A and cluster-B
# YES: compose fragment-A and fragment-B into one cluster
kixClusters.merged = kixpkgs.lib.mkCluster {
  basePackages = clusterSelf:
    (cluster-a-repo.kixFragments.default clusterSelf)
    // (cluster-b-repo.kixFragments.default clusterSelf);
};
```

If a repo only exposes `kixClusters` (evaluated) but not `kixFragments` (composable), it's a leaf — you can deploy it but not compose it. This is intentional: exporting fragments is opting into composability.

### Flake follows pinning

Flake lock files pin exact versions of every input. This gives you:
- **Reproducible clusters**: same lock file → same store paths → same deployment
- **Auditable updates**: `nix flake update team-backend` shows exactly what changed
- **Independent team velocity**: each team pins kixpkgs independently, updates on their schedule
- **Diff across versions**: compare store paths before/after a flake update to see which K8s resources changed

### Package reuse across flakes

Package constructors from kixpkgs (or any flake) are just paths to `.nix` files. `callPackage` doesn't care where they come from:

```nix
# Team uses postgres from kixpkgs, api from their own repo
api = clusterSelf.callPackage ./packages/api.nix {};
postgres = clusterSelf.callPackage kixpkgs.packages.postgres { storage = "100Gi"; };

# Team uses a custom postgres fork from another flake
postgres = clusterSelf.callPackage custom-postgres.kixPackages.postgres { storage = "100Gi"; };
```

DI resolution works the same regardless of where the package constructor came from. The instance is what matters, not its origin.

---

## Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Cluster defs | Functions (`self: { ... }`), NOT plain attrsets | Need `self` for callPackage and cross-references |
| DI mechanism | callPackage + DNS-like resolution | Auto-injection with namespace-local priority |
| Instances | ARE actual packages, not config descriptions | One model, not two; override/compose work directly |
| Aliases | Both fixpoint assignment AND metadata-based resolution | Different use cases: explicit binding vs DI discovery |
| Namespace | Via scope (auto-injected dep on namespace resource) | Packages don't handle namespace directly |
| Composition | Two models kept open: self-functions vs overlays | Let team workflow drive the choice |
| Dep tracking | Native `${}` + `builtins.getContext` | Eliminates refs.nix + resolve.nix (~165 lines) |
| `requires` in hash | Yes — full deployment graph in the Merkle DAG | Store is self-describing; no separate closure computation |
| Override | `override` (args) + `overrideParts` (fixpoint) | Two granularities, both return real packages |
| CRD deps | `requires` via type providers | `${}` can't track CR→CRD relationship |
| Hashing | `builtins.toFile` (content-addressed) | Lighter than derivation; upgradeable if needed |
| Flake composition | Fragments compose before fixpoint, never merge evaluated clusters | Store paths are final after evaluation; DI resolution needs a single fixpoint |
| Flake outputs | `kixFragments`, `kixOverlays`, `kixPackages`, `kixClusters` | Mirrors nixpkgs conventions; fragments opt into composability |

---

## What This Is NOT

- **Not a module system.** No `mkOption`, no `config`, no `imports`. Packages are functions that return fixpoints, not module declarations that get merged.
- **Not a config interpreter.** `evaluateCluster` doesn't interpret config blobs into packages. `mkCluster` evaluates a fixpoint of actual packages.
- **Not a DSL-to-packages pipeline.** There's no translation step. What you write is what you get — a package is a package at every level.

---

## Resulting DAG: Full Example

Given:

```nix
basePackages = self: {
  postgres = self.callPackage ./packages/postgres.nix { storage = "100Gi"; };
  api = self.callPackage ./packages/api.nix {};
  # api's function signature: { scope, postgres, ... }: ...
  # → postgres is auto-resolved by callPackage
};
```

The store graph for `api.main` (readable via `nix-store --query --references`, recursively):

```
Service/api@backend
├── Namespace/backend                        (content dep via scope)
└── Deployment/api@backend                   (requires — ordering dep)
     ├── Namespace/backend                   (content dep via scope)
     └── Service/postgres@data               (content dep from ${postgres.fqdn})
          ├── Namespace/data                 (content dep via scope)
          └── Deployment/postgres@data       (requires — ordering dep)
               ├── Namespace/data            (content dep via scope)
               ├── PVC/postgres-data@data    (content dep from ${self.pvc})
               └── ConfigMap/postgres@data   (content dep from ${self.configmap})
```

Both content deps and ordering deps are store references. There is no distinction at the store level — they're all inputs. A deploy tool walks this tree, topologically sorts, and gets:

```
Deploy order:
  1. Namespace/data, Namespace/backend        (leaves — no deps)
  2. PVC, ConfigMap                           (dep on namespace only)
  3. Deployment/postgres                      (deps on PVC, ConfigMap)
  4. Service/postgres                         (requires Deployment/postgres)
  5. Deployment/api                           (dep on Service/postgres)
  6. Service/api                              (requires Deployment/api)
```

No kix re-evaluation needed. The store paths are the source of truth.

---

## Discussion Documents

For detailed analysis of individual topics, including alternatives considered:

- `01_evaluateCluster_merging.md` — Merging approaches, team isolation
- `02_cluster_fixpoint_aliasing.md` — Outer fixpoint, alias resolution, DI algorithm
- `03_package_fixpoint_resources.md` — mkResource, native tracking, post-processor
- `04_namespace_scope.md` — Namespace packages, scope, cross-namespace refs
- `05_crds_type_providers.md` — Type providers, shared CRDs
- `06_team_dx_multi_deploy.md` — Composition primitives, multi-deploy, env overrides
