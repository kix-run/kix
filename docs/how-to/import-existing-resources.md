# Import Existing Cluster Resources

When deploying into a cluster that already has services running (e.g., a shared Valkey, a platform-managed cert-manager), you don't want kix to redeploy them. Instead, you **import** them: tell kix they exist so that other packages can depend on them via the normal DI system.

## When to use imports

- A service (database, cache, operator) is managed by another team or tool
- You're incrementally adopting kix in an existing cluster
- You want kix packages to reference external services with correct `out` values (fqdn, port, selector) without managing their lifecycle

## Quick example

```nix
# clusters/my-cluster.nix
{ kix, packages }:

kix.buildCluster {
  name = "my-cluster";
  modules = [{
    instances = {
      cache = {
        valkey = {
          package = kix.mkImport { from = packages.valkey; };
          aliases = [ "valkey" "redis" ];
        };
      };

      app = {
        my-app = {
          package = packages.my-app;  # has `valkey` as a DI dependency
        };
      };
    };
  }];
}
```

`my-app` receives the imported valkey via DI. `valkey.out.fqdn` resolves to `valkey.cache.svc.cluster.local` — derived from the real valkey package logic.

The only resource deployed for valkey is a lightweight **marker PackageInstance CR** with `kix.dev/mode: import`.

## `mkImport` API

```nix
kix.mkImport {
  from = <package>;  # optional: derive out from the real package
  out  = { ... };     # optional: manual out values or overrides
}
```

### Three modes

**1. Package-assisted import** — derive `out` from the real package via lazy evaluation:

```nix
package = kix.mkImport { from = packages.valkey; };
```

The real valkey build runs with a lightweight `mkResource` that only computes `out` (name, fqdn, selector, port). No manifests are created. Nix laziness ensures only `out`-relevant code paths evaluate.

**2. Raw import** — provide `out` values directly (no package needed):

```nix
package = kix.mkImport {
  out = {
    name = "my-redis";
    fqdn = "my-redis.databases.svc.cluster.local";
    port = "6379";
  };
};
```

Use this when no kix package exists for the external service, or when the service is outside the cluster (e.g., a managed cloud database).

**3. Mixed** — derive from the package, override specific values:

```nix
package = kix.mkImport {
  from = packages.valkey;
  out = { port = "6380"; };  # override derived port
};
```

Manual `out` values are merged on top of the package-derived ones.

## Configuring an import

When using `from`, the package's typed options are evaluated with defaults. If the external service uses non-default settings that affect `out`, provide them via the instance's `config`:

```nix
cache = {
  valkey = {
    package = kix.mkImport { from = packages.valkey; };
    config = {
      sentinel.enabled = true;
      sentinel.primarySet = "myprimary";
    };
  };
};
```

Only config values that affect `out` matter — deployment-specific settings (image, replicas, resources) are never evaluated thanks to Nix laziness.

## The marker resource

Every import deploys a **PackageInstance CR** to the cluster:

```yaml
apiVersion: kix.dev/v1alpha1
kind: PackageInstance
metadata:
  name: valkey
  namespace: cache
  annotations:
    kix.dev/mode: import
    kix.dev/import-name: valkey
    kix.dev/import-fqdn: valkey.cache.svc.cluster.local
spec:
  instanceName: valkey
  namespaceName: cache
  mode: import
```

This serves two purposes:

1. **Visibility** — `kubectl get packageinstances` shows both managed and imported services
2. **Verification** — deploy tooling can check that the expected external resource actually exists using the annotations

## How it works under the hood

When `evaluateInstance` sees a `kix-import` package, it takes a separate evaluation path:

1. Creates an **import scope** where `scope.mkResource` is swapped for a lightweight version (`mkImportResource`) that computes `out` without creating store paths
2. Calls the real package build with null dependencies and runs the fixpoint — Nix laziness means only the `out` derivation chain evaluates
3. Merges manual `out` overrides on top
4. Creates the marker PackageInstance CR
5. Skips resource collection, closure computation, and warnings entirely

The import instance participates fully in DI resolution — other packages receive it through the normal `{ scope, lib, valkey }:` function args.

## Tips

- **Instance name and aliases matter** — DI resolution matches package argument names against instance names and aliases. If your instance is named `valkey`, packages with a `valkey` argument will find it automatically. Add `aliases = ["redis"]` if packages ask for `redis`.
- **Adopting an import** — to take over management of an imported service, replace `kix.mkImport { ... }` with the real package. The `out` shape is identical, so downstream consumers don't change.
- **No dependency args needed** — the import doesn't resolve its own dependencies (they're passed as null). This is fine because only `out` is evaluated.
