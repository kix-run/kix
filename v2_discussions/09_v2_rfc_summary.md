# kixpkgs v2 — RFC Summary

**For:** Team review and feedback
**Full design:** `08_v2_unified_rfc.md` (1400 lines, all internals)
**Status:** Implemented, ready for review. v1 continues to work alongside v2.

---

## What changed and why

v1 packages look like this:

```nix
{ k8s, lib }:
k8s.mkPackage
  ({ namespace ? "kube-system", image ? {...}, ... }:
   self: {
    configmap = k8s.mkResource { inherit namespace; name = "coredns"; data = ...; };
    workload  = k8s.mkResource { inherit namespace; name = "coredns";
      spec.template.spec.volumes = [{
        configMap.name = self.configmap.ref;  # <-- custom ref system
      }];
    };
    service   = k8s.mkResource { inherit namespace; name = "coredns"; outputs = { port = 53; }; };
    main = k8s.withRequires [ self.workload ] self.service;
  })
  { namespace = "kube-system"; }
```

Three problems:

1. **Manual wiring.** Every cluster file imports each package, passes `{ k8s, lib }`, calls `.override { namespace = ...; clusterLabels = ...; }`. Add a package, touch every cluster file.
2. **Custom ref system.** `self.configmap.ref` and `k8s.str [...]` are kixpkgs inventions. Forget `.ref` and the dependency is silently lost. Forget `k8s.str` and use `${}` — same silent failure.
3. **No namespace structure.** Packages declare their own namespace as a string argument. Nothing enforces that two packages in the same namespace share a Namespace resource, or that namespace policies exist.

v2 fixes all three.

---

## What a v2 package looks like

```nix
# packages/coredns/default.nix
{ scope, config, lib }:

let cfg = scope.defaults config {
  image = "registry.k8s.io/coredns/coredns:v1.11.1";
  replicas = 2;
};
in self: {

  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${scope.instanceName}-coredns";
    data.Corefile = cfg.corefile;
  };

  workload = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-coredns";
    spec.template.spec.volumes = [{
      configMap.name = "${self.configmap}";   # <-- just normal Nix interpolation
    }];
  };

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${scope.instanceName}-coredns";
    outputs = { port = "53"; };
    spec.ports = [{ port = 53; }];
  };

  main = self.service // { requires = [ self.workload ]; };
}
```

What's different:

| v1 | v2 | Why |
|---|---|---|
| `self.configmap.ref` | `"${self.configmap}"` | Native Nix — impossible to forget |
| `k8s.str [ "a" x "b" ]` | `"a${x}b"` | Same reason |
| `k8s.mkResource { namespace = ...; }` | `scope.mkResource { ... }` | Namespace injected by the system |
| `k8s.withRequires [...] res` | `res // { requires = [...]; }` | Simpler, same semantics |
| `name = "coredns"` | `name = "${scope.instanceName}-coredns"` | Multi-instance safe |
| `{ k8s, lib }:` wrapper | `{ scope, config, lib }:` | Dependencies are injected |

The package never mentions a namespace. It never imports `k8s`. It gets `scope` (with the namespace, instance name, and resource constructors) and `config` (user overrides) from the system.

---

## What a cluster definition looks like

```nix
# clusters/production.nix
{ kixv2, packages }:

kixv2.buildCluster {

  namespaces = {
    kube-system = {};
    data = {};
    production = {
      resourceQuota.hard = { "requests.cpu" = "20"; };
    };
  };

  instances = { ref, ... }: {
    kube-system = {
      coredns = {
        package = packages.coredns;
        config.replicas = 3;
      };
      reloader = {
        package = packages.reloader;
      };
    };

    data = {
      postgres = {
        package = packages.postgresql;
        config.storage = "100Gi";
      };
    };

    production = {
      api = {
        package = packages.acme-api;
        config.image = "myregistry.io/api:v2.1.0";
        # postgres is auto-resolved (unique cluster-wide)
      };
    };
  };
}
```

### What you get from this

- **Namespaces are real.** Each namespace becomes a Namespace resource. Policies (quotas, network policies) are declared alongside. Every resource in `kube-system` automatically depends on the Namespace resource.

- **Instances are scoped.** Two teams can both name something `cache` in different namespaces — no conflict. The cluster is `{ namespace → { instance → package } }`, mirroring K8s itself.

- **Dependencies are injected.** If `acme-api` takes `{ scope, config, postgres }:` as its function signature, the system finds the `postgres` instance automatically. Same-namespace first, then cluster-wide. No manual wiring for the common case.

- **Explicit override when you want it.** `postgres = ref.data.postgres` in the instance config bypasses auto-resolution.

---

## Dependency injection in practice

When a package declares a dependency as a function argument:

```nix
# packages/my-app/default.nix
{ scope, config, postgres, valkey }:
self: {
  deployment = scope.mkResource {
    ...
    spec.template.spec.containers = [{
      env = [
        { name = "DB_URL"; value = "postgresql://${postgres.fqdn}:${postgres.out.port}/mydb"; }
        { name = "CACHE";  value = "redis://${valkey.fqdn}:${valkey.out.port}"; }
      ];
    }];
  };
  ...
}
```

The system:
1. Looks at the function's arguments (`postgres`, `valkey`)
2. Searches the cluster for instances matching those names (by package type or alias)
3. Injects the fully-evaluated instances

Resolution order:
```
1. Explicit override in instance config     →  user wired it
2. Same-namespace match                     →  DNS-local
3. Cluster-wide unique match                →  DNS-search
4. Nix function default (? syntax)          →  package fallback
5. Error with helpful message               →  missing dep
```

When it's ambiguous (two `postgres` instances cluster-wide), you get a clear error telling you to wire it explicitly.

---

## Scope API

Every package receives `scope` with:

| Attribute | What it is |
|---|---|
| `scope.instanceName` | The instance name from the cluster config |
| `scope.namespaceName` | The namespace as a string |
| `scope.namespace` | The Namespace resource (for explicit refs) |
| `scope.mkResource { ... }` | Creates a namespaced resource (namespace + labels auto-injected) |
| `scope.mkClusterResource { ... }` | Creates a cluster-scoped resource (ClusterRole, etc.) |
| `scope.defaults config { ... }` | Merges user config with package defaults |

---

## Environments: same services, different configs

```nix
instances = { ref, ... }:
  # Shared infra
  { kube-system.coredns = { package = packages.coredns; }; }

  # Dev: small
  // kixv2.mkEnv "dev" { config = { pgStorage = "10Gi"; }; } {
    app = appStack;
    data = dataStack;
  }

  # Prod: big
  // kixv2.mkEnv "prod" { config = { pgStorage = "200Gi"; }; } {
    app = appStack;
    data = dataStack;
  };
```

`mkEnv "dev" {...} { app = ...; data = ...; }` produces namespaces `dev-app` and `dev-data` with all instances stamped in. Resolution prefers same-env instances, preventing `dev-app/api` from accidentally connecting to `prod-data/postgres`.

---

## Multi-team: fragments

Each team produces a fragment:

```nix
# teams/platform/fragment.nix
{ packages }: {
  namespaces.kube-system = {};
  instances = { ref, ... }: {
    kube-system.coredns = { package = packages.coredns; };
  };
}
```

The cluster assembles them:

```nix
kixv2.buildCluster (
  kixv2.mergeFragments {
    fragments = [ platformFragment backendFragment mlFragment ];
    namespacePolicies = { production.resourceQuota.hard."requests.cpu" = "20"; };
  }
)
```

Instance collision (same name+namespace from two fragments) is an error. Namespace policies deep-merge. Cross-fragment dependencies work through DI auto-resolution.

---

## Migration path

v2 runs alongside v1. The flake exports both:

```
nix build .#cluster-example       # v1
nix build .#v2-cluster-example    # v2
```

Packages are migrated one at a time into `packages/`. Cluster definitions are rewritten into `clusters/v2/`. v1 code stays untouched until everything is validated.

All 12 packages are migrated. The v2 smoke test suite passes. v1 tests continue to pass.

---

## What I'd like feedback on

1. **DI resolution order.** Same-namespace → cluster-wide → Nix default → error. Does this feel right? Should we add env-scope as a resolution step between same-namespace and cluster-wide?

2. **Resource naming.** v2 prefixes all resource names with `${scope.instanceName}-`. This means `coredns` becomes `coredns-coredns` when the instance is named `coredns`. Naming suggestions welcome.

3. **Namespace for cross-namespace resources.** Some packages (network-policies, arc) create resources in namespaces other than their own. Currently handled via `scope.mkClusterResource` + `extra.metadata.namespace`. Better pattern?

4. **Fragment granularity.** Is one fragment per team the right split? Or per-service? Per-namespace?

5. **Anything that feels like it would hurt day-to-day DX.** The goal is that the common case requires less code than v1, and the escape hatches exist for uncommon cases.

---

*Full implementation details, closure computation, post-processing, and all edge cases are in `08_v2_unified_rfc.md`.*
