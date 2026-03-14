# Namespaces as Resource Dependencies and the Scope Mechanism

## Working Document — March 2026

**Status:** Design exploration (not yet implemented)
**Dependencies:** `03_native-store-path-tracking.md` (resources as derivations), `06_cluster-dsl.md` (cluster composition)

---

## 1. The Problem

In the current v1 implementation, namespaces are strings. Every resource takes `namespace ? "default"` as a plain string argument. This creates three problems:

1. **No dependency tracking.** A Namespace must exist before resources in it can be created. With string namespaces, there's no dep edge from Deployment to its Namespace — the deploy ordering is wrong.
2. **No policy bundling.** A Namespace typically carries ResourceQuota, LimitRange, and NetworkPolicy resources. These are invisible when the namespace is just a string.
3. **Repetitive boilerplate.** Every `mkResource` call in a package repeats `inherit namespace;`. The package author must thread the namespace through manually.

The v1 code makes this visible — look at `pkgs-fp/coredns/default.nix`: every single resource call includes `inherit namespace;`, and cluster-scoped resources use `namespace = null`. There's no structural connection between "this resource is in kube-system" and "the kube-system Namespace resource exists."

---

## 2. Design Principles

Before diving into mechanisms, the constraints:

1. **Namespace is a K8s resource.** It's `apiVersion: v1, kind: Namespace`. It must be a derivation in the DAG, not a string.
2. **Namespace dependency must be automatic.** If a resource is in namespace X, it depends on the Namespace/X resource. Package authors should not declare this manually.
3. **Packages should not know their namespace.** A package like postgres should work in any namespace. The namespace assignment happens at the cluster/scope level, not inside the package.
4. **Cluster-scoped resources exist.** ClusterRole, PersistentVolume, ClusterRoleBinding, CRDs — these have no namespace. The mechanism must handle them cleanly.
5. **Cross-namespace references produce FQDNs.** When my-app (in namespace `production`) references postgres.service (in namespace `data`), the result is `postgres.data.svc.cluster.local`, not just `postgres`.

---

## 3. The Namespace Resource

### 3.1 Namespace as a Package (Inner Fixpoint)

A namespace is itself a small package — a self-referential set of resources with an inner fixpoint. The Namespace object is the `main`, and it carries policy resources via `requires`:

```nix
mkNamespace = { name, labels ? {}, resourceQuota ? null, limitRange ? null, networkPolicies ? [] }:
  let
    self = lib.fix (ns: {
      namespace = mkResource {
        apiVersion = "v1";
        kind = "Namespace";
        inherit name;
        namespace = clusterScoped;   # Namespace itself is cluster-scoped
        labels = labels // { "kubernetes.io/metadata.name" = name; };
        requires =
          lib.optional (resourceQuota != null) ns.quota
          ++ lib.optional (limitRange != null) ns.limitRange
          ++ map (i: builtins.elemAt ns.netpols i) (lib.range 0 (builtins.length networkPolicies - 1));
      };

      quota = mkResource {
        apiVersion = "v1";
        kind = "ResourceQuota";
        name = "${name}-quota";
        namespace = name;            # The quota IS in the namespace (string here — see 3.2)
        spec.hard = resourceQuota;
      };

      limitRange = mkResource {
        apiVersion = "v1";
        kind = "LimitRange";
        name = "${name}-limits";
        namespace = name;
        spec.limits = limitRange;
      };

      netpols = lib.imap0 (i: pol:
        mkResource {
          apiVersion = "networking.k8s.io/v1";
          kind = "NetworkPolicy";
          name = "${name}-netpol-${toString i}";
          namespace = name;
          spec = pol;
        }
      ) networkPolicies;

      # The public interface — the Namespace resource itself
      main = ns.namespace;
    });
  in self;
```

Why a package with inner fixpoint rather than a single resource? Because the Namespace carries policy resources that must be in its closure. When you depend on the namespace, you transitively get its ResourceQuota, LimitRange, and NetworkPolicies via `requires`. This means deploy ordering is correct: Namespace first, then its policies, then the resources that live in it.

### 3.2 Bootstrapping Problem: Policy Resources Inside the Namespace

There's a subtle circularity: the Namespace resource carries its policies via `requires`, but those policies (ResourceQuota, NetworkPolicy) live *inside* that namespace. In the v2 derivation model, resources inside a namespace would normally depend on the Namespace resource (creating the dep automatically via scope). But the policies are *part of* the namespace package, not consumer packages.

Resolution: namespace policy resources use the namespace name as a plain string, not a scope-injected namespace resource. They're created by `mkNamespace` directly, which knows the name. They don't go through `scope.mkResource` — they're internal to the namespace package. The automatic namespace dependency injection (via scope) only applies to resources from *consumer* packages.

```
Namespace/data (cluster-scoped)
  ├─ requires → ResourceQuota/data-quota (ns: data, plain string)
  ├─ requires → LimitRange/data-limits (ns: data, plain string)
  └─ requires → NetworkPolicy/data-netpol-0 (ns: data, plain string)

Deployment/postgres (ns: data) ──dep──→ Namespace/data   ← injected by scope
```

The policy resources use `namespace = name` (the string), not `namespace = ns.namespace` (the resource). They don't need a dep on the Namespace resource because they ARE the namespace's resources — they deploy together as one closure.

### 3.3 `clusterScoped` Sentinel

Cluster-scoped resources (ClusterRole, PersistentVolume, CRD, the Namespace resource itself) have no namespace. In v1, this is `namespace = null`. In v2, we need a sentinel value that:

1. Tells `mkResource` to omit `metadata.namespace` from the manifest
2. Does NOT create a dependency on any Namespace resource
3. Is distinguishable from "forgot to set namespace" (which should be an error)

```nix
clusterScoped = {
  _type = "k8s-cluster-scoped";
  __toString = _: "";
  name = null;
};
```

In the v2 derivation model, `clusterScoped` doesn't have an `outPath` — it's not a derivation. When the resource identity derivation is created, it uses `"_cluster_"` for the namespace component of the hash, matching v1 behavior.

`scope.mkClusterResource` pre-binds `namespace = clusterScoped` so package authors just write:

```nix
clusterRole = scope.mkClusterResource {
  apiVersion = "rbac.authorization.k8s.io/v1";
  kind = "ClusterRole";
  name = "coredns";
  rules = [ ... ];
};
```

---

## 4. The Scope Mechanism

### 4.1 What Scope Contains

Scope is the bridge between the cluster-level configuration and individual packages. It's created per-instance in the outer fixpoint and injected via `callPackage` / `kixCallPackage`.

```nix
mkScope = { instanceName, namespaceName, namespaceResource, clusterLabels }:
  let
    ns = namespaceResource;   # the Namespace derivation from mkNamespace
  in {
    inherit instanceName;

    # The namespace resource — for packages that need to reference it explicitly
    namespace = ns;

    # The namespace name as a string — for FQDNs, labels, etc.
    namespaceName = namespaceName;

    # Create a namespaced resource. Automatically:
    #   1. Sets metadata.namespace to the namespace name
    #   2. Adds a dependency on the Namespace resource (via native ${})
    #   3. Merges cluster-wide labels
    mkResource = args: k8s.mkResource (args // {
      namespace = ns;                     # the resource object, not a string
      labels = (clusterLabels // (args.labels or {}));
    });

    # Create a cluster-scoped resource. No namespace, no namespace dep.
    mkClusterResource = args: k8s.mkResource (args // {
      namespace = clusterScoped;
      labels = (clusterLabels // (args.labels or {}));
    });
  };
```

### 4.2 How `scope.mkResource` Injects the Namespace Dependency

This is the key mechanism. When `scope.mkResource` passes `namespace = ns` (where `ns` is the Namespace derivation), two things happen:

**In v1 (custom ref tracking):** `ns` is a resource with a `.ref` field. The `mkResource` implementation sees `namespace = ns` and does:
- Sets `metadata.namespace = toString ns.ref` (the namespace name)
- Adds `ns` to `deps` (the Namespace resource is now a dependency)

**In v2 (native store path tracking):** `ns` is a derivation with an `outPath`. The `mkResource` implementation does:
- `metadata.namespace` gets the namespace name (either from `ns.name` or by post-processing the store path)
- The dependency is tracked natively because the namespace's store path appears in the resource's identity derivation

The implementation detail in `mkResource` for handling the namespace argument:

```nix
mkResource = { namespace, ... }@args:
  let
    # Determine if namespace is a resource or the clusterScoped sentinel
    isClusterScoped = namespace._type or "" == "k8s-cluster-scoped";
    isNamespaceResource = namespace._type or "" == "k8s-resource"
                          || namespace ? outPath;  # v2: it's a derivation

    # Extract the actual namespace name for the manifest
    nsName =
      if isClusterScoped then null
      else if isNamespaceResource then namespace.name  # or: toString namespace
      else namespace;  # plain string fallback (for namespace-internal resources)

    # Track the namespace as a dependency
    nsDeps =
      if isNamespaceResource then [ namespace ]  # v1: explicit dep
      else [];                                   # cluster-scoped or string: no dep

    # In v2, the dep is implicit via ${namespace} in the identity derivation content
  in
  # ... build the resource with nsName in metadata and nsDeps in deps ...
```

### 4.3 What Scope Does NOT Contain

Scope is deliberately minimal. It does NOT contain:
- The package's own config (that comes via a separate `config` argument)
- Other packages (those come via DI / the outer fixpoint)
- The full cluster configuration

This separation keeps packages testable — you can construct a scope for testing without building a full cluster:

```nix
testScope = mkScope {
  instanceName = "test-postgres";
  namespaceName = "test";
  namespaceResource = mkNamespace { name = "test"; };
  clusterLabels = {};
};
```

---

## 5. Scope and the Outer Fixpoint

### 5.1 Where Scope Is Created

Scope is created inside `buildCluster` / the outer fixpoint evaluator. For each service instance, a scope is constructed from:
1. The instance name (from the cluster config key)
2. The namespace (from the instance's config)
3. The namespace resource (from the namespace registry built in step 1 of `buildCluster`)
4. Cluster-wide labels

```nix
buildCluster = clusterConfig:
  let
    # Step 1: Build all namespace resources
    allNamespaceNames = collectNamespaces clusterConfig;  # from services.*.namespace + namespaces.*
    namespaceResources = lib.mapAttrs (name: nsCfg:
      mkNamespace {
        inherit name;
        labels = clusterConfig.cluster.labels or {};
        resourceQuota = nsCfg.resourceQuota or null;
        limitRange = nsCfg.limitRange or null;
        networkPolicies = nsCfg.networkPolicies or [];
      }
    ) allNamespaceNames;

    # Step 2: Outer fixpoint — packages see each other
    instances = lib.fix (self:
      lib.mapAttrs (instanceName: svcCfg:
        let
          nsName = svcCfg.namespace or "default";
          nsResource = namespaceResources.${nsName}.main;
          scope = mkScope {
            inherit instanceName;
            namespaceName = nsName;
            namespaceResource = nsResource;
            clusterLabels = clusterConfig.cluster.labels or {};
          };
          pkg = loadPackage (svcCfg.package or instanceName);
        in kixCallPackage pkg scope svcCfg self
      ) clusterConfig.services
    );
  in { ... };
```

### 5.2 Scope and callPackage

The `kixCallPackage` function (from doc 04) injects `scope` alongside `config` and resolved dependencies:

```nix
kixCallPackage = packageFn: scope: instanceConfig: allInstances:
  let
    resolvedDeps = resolveDeps packageFn instanceConfig allInstances;
  in packageFn ({
    inherit scope;
    config = instanceConfig;
  } // resolvedDeps);
```

The package function signature becomes:

```nix
# kixpkgs/postgres.nix
{ scope, config }:
self: {
  configmap = scope.mkResource {
    apiVersion = "v1"; kind = "ConfigMap";
    name = scope.instanceName;
    data = { ... };
  };
  # ...
}
```

Note: `namespace` is gone from the package arguments. The package doesn't know or care what namespace it's in. `scope.mkResource` handles it.

### 5.3 Scope per Instance, Not per Package

Each *instance* of a package gets its own scope. If the same package is instantiated twice in different namespaces:

```nix
services.backend-cache = { package = "valkey"; namespace = "backend"; };
services.session-store = { package = "valkey"; namespace = "data"; };
```

...then `backend-cache` gets a scope with `namespace = "backend"` and `session-store` gets a scope with `namespace = "data"`. Same package code, different scopes, different namespace dependencies.

---

## 6. Cross-Namespace References and FQDNs

### 6.1 The FQDN Mechanism

When a resource in namespace `production` references a Service in namespace `data`, the Kubernetes DNS name is `<service-name>.<namespace>.svc.cluster.local`. The system must produce this automatically.

In v2, each Service resource exposes an `fqdn` attribute:

```nix
# Inside mkResource, when kind == "Service":
self = baseResource // {
  fqdn =
    let
      nsName = if isNamespaceResource then namespace.name else namespace;
      value = "${name}.${nsName}.svc.cluster.local";
    in
    # In v2: attach the service derivation's context to the FQDN string
    builtins.appendContext value (builtins.getContext "${self}");
    # In v1: mkRef self "fqdn" value;
};
```

### 6.2 FQDN Contains the Namespace Name, Not a Store Path

The FQDN is `"postgres.data.svc.cluster.local"` — the namespace name `"data"` appears as a literal string. It is NOT a tracked reference to the Namespace resource. Why?

1. The FQDN is consumed by the K8s DNS resolver at runtime. It needs the actual name.
2. The dependency on the Namespace resource is already tracked via the Service resource's own namespace field. You don't need a second path.
3. If the namespace name were a store path in the FQDN, the post-processor would need to handle it specially (replace `/nix/store/...-Namespace-data` with `data` inside a DNS name).

The tracked context on the FQDN string points to the Service derivation, not the Namespace. The Namespace dep is transitive: depend on postgres.service -> postgres.service depends on Namespace/data -> Namespace/data is in the closure.

### 6.3 Same-Namespace Short Names

When a resource references a Service in the same namespace, the short name suffices: just `postgres`, not `postgres.data.svc.cluster.local`. The `${service}` interpolation (store path, post-processed to the service name) handles this case:

```nix
# Same namespace — short name via store path
env.DB_HOST = "${postgres.service}";
# Post-processed to: "postgres"

# Cross namespace — FQDN
env.DB_HOST = "${postgres.service.fqdn}";
# Already the correct value: "postgres.data.svc.cluster.local"
```

The package author chooses which to use. For connection strings, always use `.fqdn` — it works both same-namespace and cross-namespace. For K8s fields like `backend.service.name`, use the store path interpolation (short name).

### 6.4 Cross-Namespace Dependencies in the DAG

When my-app uses `${postgres.service.fqdn}`, the dependency chain is:

```
Deployment/myapp@production
  ├─ dep → Namespace/production        (via scope.mkResource)
  └─ dep → Service/postgres@data       (via ${postgres.service.fqdn})
             └─ dep → Namespace/data    (via scope.mkResource in postgres package)
```

Both namespaces end up in the closure. Deploy order: Namespace/data, Namespace/production, postgres resources, myapp resources.

---

## 7. Namespace Deduplication and Ownership

### 7.1 The Problem

Two teams define services in namespace "backend":

```nix
services.api     = { namespace = "backend"; ... };   # team A
services.worker  = { namespace = "backend"; ... };   # team B
```

Team A's `api` gets a scope with `namespaceResource = namespaceResources.backend.main`. Team B's `worker` gets the same `namespaceResource`. This is correct — there's one Namespace/backend resource in the cluster, and both services depend on it.

### 7.2 Namespace Policies: Merge or Conflict?

When two teams both configure the same namespace:

```nix
# Team A's overlay
namespaces.backend.resourceQuota.hard."requests.cpu" = "20";

# Team B's overlay
namespaces.backend.resourceQuota.hard."requests.memory" = "64Gi";
```

This works via normal Nix attrset merging / `recursiveUpdate` in the overlay system. The result is a single Namespace/backend with both CPU and memory quotas.

Conflicts (both teams set the same field to different values) are handled by overlay ordering — later overlays win, same as nixpkgs. This is a feature: the cluster operator controls the final config by ordering overlays.

True conflicts should be surfaced:

```nix
# Team A: namespaces.backend.resourceQuota.hard."requests.cpu" = "20";
# Team B: namespaces.backend.resourceQuota.hard."requests.cpu" = "40";
# → Last overlay wins. No error. Cluster operator decides merge order.
```

### 7.3 Ownership Model

Nobody "owns" a namespace in the object-ownership sense. The namespace is a shared resource in the cluster. Its configuration is the merged result of all cluster config + overlays. This mirrors how K8s namespaces actually work — they're shared infrastructure.

If ownership matters (e.g., for RBAC on who can modify namespace config), that's a policy concern handled outside kixpkgs (e.g., by a Git CODEOWNERS file on the cluster config, or by administrative convention).

---

## 8. Interaction with the Cluster DSL

### 8.1 Implicit Namespace Creation

When a service references a namespace that has no explicit `namespaces.*` entry, a bare namespace is created automatically:

```nix
# Only services, no explicit namespace declaration:
services.api = { namespace = "backend"; image = "..."; };

# buildCluster detects "backend" is referenced but not declared,
# creates: namespaceResources.backend = mkNamespace { name = "backend"; };
# (no quota, no limit range, no network policies)
```

This matches doc 04's behavior: "If a namespace is referenced by a service but has no `namespaces.*` entry, a bare namespace (no policies) is created automatically."

### 8.2 Namespace Config in Different DSL Approaches

From doc 06, the DSL approach affects where namespace policies are declared:

**Approach A (nested):** Policies are inline with the namespace block — clean but couples structure to namespace.

**Approach D (scope blocks):** `cluster.scope { namespace = "backend"; resourceQuota = ...; }` — policies co-located with scope.

**Approach E (just functions):** Separate `_namespaces` or `namespaces` arg to `mkCluster` — cleanest separation.

In all cases, `buildCluster` collects namespace configs and calls `mkNamespace` to produce the namespace resources. The mechanism is the same; only the DSL surface differs.

### 8.3 Environment Prefixing and Namespaces

When `prefixEnv "prod"` turns `namespace = "backend"` into `namespace = "prod-backend"`, the namespace resource is also renamed:

```nix
# Before prefixing:
namespaceResources.backend = mkNamespace { name = "backend"; ... };

# After prefixing:
namespaceResources.prod-backend = mkNamespace { name = "prod-backend"; ... };
```

FQDNs update automatically because they derive from the namespace name: `api.prod-backend.svc.cluster.local`. Cross-environment references (can `dev-api` talk to `prod-postgres`?) work via the normal resolution + reachability checking mechanism from doc 04.

---

## 9. Concrete Code: Putting It Together

### 9.1 Full mkNamespace Implementation

```nix
mkNamespace = { name, labels ? {}, resourceQuota ? null, limitRange ? null, networkPolicies ? [] }:
  lib.fix (ns: {
    # The Namespace resource itself (cluster-scoped)
    resource = mkResource {
      apiVersion = "v1";
      kind = "Namespace";
      inherit name;
      namespace = clusterScoped;
      labels = labels // {
        "kubernetes.io/metadata.name" = name;
      };
      requires =
        lib.optional (resourceQuota != null) ns.quota
        ++ lib.optional (limitRange != null) ns.limits
        ++ ns.netpols;
    };

    quota = mkResource {
      apiVersion = "v1";
      kind = "ResourceQuota";
      name = "${name}-quota";
      namespace = name;   # plain string — internal to namespace package
      spec.hard = resourceQuota;
    };

    limits = mkResource {
      apiVersion = "v1";
      kind = "LimitRange";
      name = "${name}-limits";
      namespace = name;
      spec.limits = limitRange;
    };

    netpols = lib.imap0 (i: pol:
      mkResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "NetworkPolicy";
        name = "${name}-netpol-${toString i}";
        namespace = name;
        spec = pol;
      }
    ) networkPolicies;

    # Public interface
    main = ns.resource;

    # Convenience: the namespace name as a string
    inherit name;
  });
```

### 9.2 Full mkScope Implementation

```nix
mkScope = { instanceName, namespaceName, namespaceResource, clusterLabels }:
  {
    inherit instanceName namespaceName;

    # The Namespace derivation — use for explicit references
    namespace = namespaceResource;

    # Namespaced resource constructor
    mkResource = { labels ? {}, ... }@args:
      k8s.mkResource (removeAttrs args [ "labels" ] // {
        namespace = namespaceResource;
        labels = clusterLabels // {
          "app.kubernetes.io/instance" = instanceName;
        } // labels;
      });

    # Cluster-scoped resource constructor
    mkClusterResource = { labels ? {}, ... }@args:
      k8s.mkResource (removeAttrs args [ "labels" ] // {
        namespace = clusterScoped;
        labels = clusterLabels // {
          "app.kubernetes.io/instance" = instanceName;
        } // labels;
      });

    # In v1: tracked string builder
    str = k8s.str;
    # In v2: not needed (native ${} everywhere)
  };
```

### 9.3 Package Using Scope (v2 Style)

```nix
# kixpkgs/postgres.nix
{ scope, config }:
self: {
  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = scope.instanceName;
    # namespace is automatically set by scope.mkResource
    # dep on Namespace resource is automatically tracked
    data.postgresql.conf = config.postgresqlConf or "";
  };

  pvc = scope.mkResource {
    apiVersion = "v1";
    kind = "PersistentVolumeClaim";
    name = "${scope.instanceName}-data";
    spec.resources.requests.storage = config.storage or "10Gi";
  };

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = scope.instanceName;
    requires = [ self.serviceAccount ];
    spec.template.spec = {
      serviceAccountName = "${self.serviceAccount}";
      containers = [{
        name = "postgres";
        image = "postgres:${config.version or "16"}";
        volumeMounts = [{ name = "data"; mountPath = "/var/lib/postgresql/data"; }];
      }];
      volumes = [{
        name = "data";
        persistentVolumeClaim.claimName = "${self.pvc}";
      }];
    };
  };

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = scope.instanceName;
    requires = [ self.clusterRoleBinding ];
  };

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-binding";
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io";
      kind = "ClusterRole";
      name = "${self.clusterRole}";
    };
    subjects = [{
      kind = "ServiceAccount";
      name = "${self.serviceAccount}";
      namespace = scope.namespaceName;   # string — for the binding's subject
    }];
  };

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-role";
    rules = [{ apiGroups = [""]; resources = ["configmaps"]; verbs = ["get"]; }];
  };

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = scope.instanceName;
    outputs = { port = 5432; };
    spec = {
      selector = { "app.kubernetes.io/instance" = scope.instanceName; };
      ports = [{ port = 5432; targetPort = 5432; }];
    };
  };

  main = k8s.withRequires [ self.deployment self.configmap self.pvc ] self.service;
}
```

### 9.4 Cross-Namespace Consumer

```nix
# kixpkgs/my-app.nix
{ scope, config, postgres }:
self: {
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = scope.instanceName;
    spec.template.spec.containers = [{
      name = "app";
      image = config.image;
      env = [{
        name = "DATABASE_URL";
        # v2 native interpolation — dep on postgres.service tracked via store path context
        value = "postgresql://${postgres.service.fqdn}:${postgres.service.out.port}/mydb";
        # Produces: "postgresql://postgres.data.svc.cluster.local:5432/mydb"
        # with context tracking dep on postgres.service derivation
      }];
    }];
  };

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = scope.instanceName;
    spec.selector = { "app.kubernetes.io/instance" = scope.instanceName; };
  };

  main = k8s.withRequires [ self.deployment ] self.service;
}
```

### 9.5 Cluster Assembly

```nix
mkCluster {
  namespaces.data = {
    resourceQuota.hard."requests.storage" = "500Gi";
  };
  namespaces.production = {};

  services.postgres = {
    namespace = "data";
    storage = "100Gi";
    version = "16";
  };

  services.my-app = {
    namespace = "production";
    image = "myapp:v2.1.0";
    # postgres resolved automatically via doc 04 mechanism
  };
}
```

### 9.6 Resulting DAG

```
Namespace/data (cluster-scoped)
  ├─ requires → ResourceQuota/data-quota (ns: data)
  │
  Namespace/production (cluster-scoped)
  │
  Service/postgres@data
  ├─ dep → Namespace/data                    ← injected by scope
  ├─ requires → Deployment/postgres@data
  │              ├─ dep → Namespace/data      ← injected by scope
  │              ├─ dep → PVC/postgres-data@data
  │              │         └─ dep → Namespace/data
  │              └─ dep → ServiceAccount/postgres@data
  │                        └─ requires → ClusterRoleBinding/postgres-binding (cluster-scoped)
  │                                       └─ dep → ClusterRole/postgres-role (cluster-scoped)
  ├─ requires → ConfigMap/postgres@data
  │              └─ dep → Namespace/data
  └─ requires → PVC/postgres-data@data
                 └─ dep → Namespace/data

  Service/my-app@production
  ├─ dep → Namespace/production              ← injected by scope
  └─ requires → Deployment/my-app@production
                 ├─ dep → Namespace/production
                 └─ dep → Service/postgres@data   ← via ${postgres.service.fqdn}

Deploy order (topologically sorted):
  1. Namespace/data, Namespace/production        (no deps)
  2. ResourceQuota/data-quota                    (needs Namespace/data)
  3. ClusterRole, ClusterRoleBinding             (cluster-scoped, no ns dep)
  4. ServiceAccount, ConfigMap, PVC              (need Namespace/data)
  5. Deployment/postgres                         (needs SA, CM, PVC)
  6. Service/postgres                            (needs Deployment)
  7. Deployment/my-app                           (needs Service/postgres, Namespace/production)
  8. Service/my-app                              (needs Deployment/my-app)
```

---

## 10. Edge Cases and Design Decisions

### 10.1 kube-system and Other Pre-Existing Namespaces

Some namespaces (kube-system, default, kube-public) already exist on every cluster. Should kixpkgs still create Namespace resources for them?

Yes. The Namespace resource is idempotent — `kubectl apply` on an existing namespace updates labels/annotations but doesn't recreate it. Having the resource in the DAG ensures:
- Labels and annotations are managed
- Policy resources (quotas, network policies) are properly ordered
- The DAG is complete (no invisible dependencies)

### 10.2 Namespace Deletion Safety

K8s cascades namespace deletion — deleting a Namespace deletes everything in it. kixpkgs should NEVER delete a Namespace resource during a diff/apply. This is a deploy-tool concern (the changeset visualizer / apply tool), not a DAG concern, but worth noting: the Namespace resource in the DAG should be marked as `prevent-delete` or equivalent.

### 10.3 Resources That Span Multiple Namespaces

The v1 `network-policies` package creates resources in many different namespaces (one CiliumNetworkPolicy per internal namespace). This doesn't use scope — it manually specifies `namespace = ns` as a string for each resource.

In v2, such packages have two options:

1. **Don't use scope.** Pass `k8s` directly and specify namespaces manually. This is appropriate for cluster-infrastructure packages that inherently span namespaces.

2. **Receive multiple scopes.** The package takes a list of scopes or namespace resources:
   ```nix
   { k8s, namespaceResources, config }:
   self: {
     policies = lib.mapAttrs (nsName: nsRes:
       k8s.mkResource {
         apiVersion = "cilium.io/v2";
         kind = "CiliumNetworkPolicy";
         name = "internal-traffic-${nsName}";
         namespace = nsRes.main;   # creates dep on each namespace
         spec = { ... };
       }
     ) namespaceResources;
   }
   ```

Option 1 is simpler and matches the current v1 pattern. Option 2 is more "correct" but adds complexity for a rare case. Recommendation: use option 1 for infrastructure packages, option 2 only when you need namespace resource dependencies.

### 10.4 `scope.namespaceName` — Why Expose the String?

Even though scope injects the namespace resource, packages sometimes need the namespace as a plain string:
- In ClusterRoleBinding subjects: `subjects = [{ namespace = scope.namespaceName; ... }]`
- In labels: `"namespace" = scope.namespaceName;`
- In environment variables: `NAMESPACE = scope.namespaceName;`

These are cases where you want the string "data", not a dependency on the Namespace resource. `scope.namespaceName` provides this without requiring the package to introspect the namespace resource.

### 10.5 Namespace Labels and the Scope

The Namespace resource carries labels (from cluster config + namespace config). These labels are used by NetworkPolicy namespace selectors. When scope creates a resource, it merges `clusterLabels` into the resource's labels, but namespace-specific labels (like `"team" = "data"`) are on the Namespace resource, not on resources inside it.

If a resource needs to match a namespace label selector, it references the Namespace resource's labels — it doesn't inherit them automatically. This is correct: K8s namespace selectors match on the Namespace object's labels, not on the labels of resources inside it.

---

## 11. Summary of Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Namespace is a resource | Yes, a derivation in the DAG | Needed for deploy ordering and policy bundling |
| Namespace is a package (inner fixpoint) | Yes, with `requires` on policies | Policies must be in the namespace's closure |
| Scope creates namespace dep automatically | Yes, via `scope.mkResource` | Package authors should not think about namespace deps |
| Namespace policies use plain string namespace | Yes, not scope-injected | Avoids circular dependency with the namespace they're defining |
| `clusterScoped` sentinel | Attrset with `_type` tag | Distinguishable from null and from strings |
| FQDN contains namespace name as string | Yes, not a tracked store path | It's a DNS name, not a K8s reference. Namespace dep is transitive via the service. |
| Implicit namespace creation | Yes, bare namespace if not declared | Reduces boilerplate for simple cases |
| Multi-namespace packages | Use `k8s` directly, not scope | Scope is per-instance; infrastructure packages are special |
| Pre-existing namespaces (kube-system) | Create Namespace resource anyway | Idempotent; ensures complete DAG |

---

## 12. Open Questions

### 12.1 Should mkResource Accept Both String and Resource Namespaces?

The current design allows `namespace` to be a string (for backward compat and namespace-internal resources) or a resource (for scope-injected deps). This dual acceptance adds a conditional branch in `mkResource`. Alternative: require all callers to pass either a resource or `clusterScoped`, and provide a separate `mkNamespaceInternalResource` for namespace policy resources. This is more strict but more verbose.

### 12.2 How Does Namespace Interact with Auto-Install (Doc 05)?

When auto-install creates a dependency (e.g., auto-installing postgres because my-app needs it), what namespace does the auto-installed package go in? Options:
- Same namespace as the requester (scope inheritance)
- A default namespace for auto-installed infra (e.g., "data")
- Require explicit namespace declaration (error if not specified)

This interacts with the DSL: the auto-install mechanism needs a way to assign namespaces to auto-created instances.

### 12.3 Namespace Resource Deduplication Across Packages

If two packages explicitly create Namespace resources for "data" (outside of the `buildCluster` mechanism), they'd produce two different derivations with the same K8s identity. The cluster-level deduplication (doc 03, section 6.2) handles this by registry identity, but which one wins? The `buildCluster` approach (step 1 creates all namespaces centrally) avoids this by construction — only `buildCluster` creates namespace resources, never individual packages.

### 12.4 Should `scope.mkResource` Accept a `namespace` Override?

What if a resource inside a package needs to be in a different namespace than the scope? Current design: `scope.mkResource` always uses the scope's namespace — if you need a different namespace, use `k8s.mkResource` directly. This makes the override explicit and visible. Alternative: allow `scope.mkResource { namespace = otherNs; ... }` to override. Risk: silent overrides where a package puts resources in unexpected namespaces.

Recommendation: don't allow override. If a package needs multi-namespace resources, it should receive `k8s` directly and declare its intent explicitly.
