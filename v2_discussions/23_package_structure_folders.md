# 23: Package Structure — Folders, Raw, and Auto-Exposed Contracts

## Working Document — March 2026

**Status:** Design exploration
**Predecessors:** doc 03 (package fixpoint), doc 07 (instance design), doc 11 (infrastructure DI), doc 21 (CRD builders), doc 22 (secrets DI)

---

## 1. The Problem

Today, a package's `self` attrset is a flat bag of resources. The package author
must manually wire things onto `out` to make them accessible to DI consumers:

```nix
self: {
  crdCertificates = mkCRD { ... };
  crdCertificateRequests = mkCRD { ... };
  controllerDeployment = scope.mkResource { ... };
  webhookDeployment = scope.mkResource { ... };
  controllerService = scope.mkResource { ... };
  main = self.controllerDeployment;

  # Author must know: "expose CRDs for consumers"
  out.crds.certificates = self.crdCertificates;
  out.crds.certificateRequests = self.crdCertificateRequests;
}
```

This has three issues:

1. **Knowledge burden.** The package author must learn the `out` conventions.
   Forgetting to expose something means consumers can't access it. There's no
   feedback — you only discover the omission when a consumer tries to use it.

2. **No structural distinction.** Looking at a package, there's no way to tell
   which resources are public contract vs internal implementation. CRDs,
   secrets, deployments, services — all sit at the same level.

3. **Manual wiring is redundant.** If a package creates a secret with
   `scope.mkSecret`, the evaluator already knows it's a secret. The author
   shouldn't need to also say "and please expose this as a secret."

---

## 2. The Proposal: Folders

Package authors organize resources into **well-known keys** ("folders") on
`self`. The evaluator recognizes these folders and auto-exposes them to DI
consumers. Resources not placed in any folder are swept into `raw`.

### 2.1 What the Package Author Writes

```nix
# packages/postgres/default.nix
{ scope, config, storage, credentials ? null }:

self: {
  meta = {
    lifecycle = "stateful";
  };

  secrets.credentials = if credentials != null
    then credentials
    else scope.mkSecret {
      name = "${scope.instanceName}-credentials";
      keys = [ "username" "password" "host" "port" ];
      generate = {
        password = { type = "random"; length = 32; };
        username = { type = "fixed"; value = "postgres"; };
      };
    };

  statefulset = scope.mkResource {
    kind = "StatefulSet";
    name = scope.instanceName;
    spec.template.spec.containers = [{
      name = "postgres";
      env = [
        (self.secrets.credentials.out.keyRef "password"
          // { name = "POSTGRES_PASSWORD"; })
      ];
    }];
  };

  service = scope.mkResource {
    kind = "Service";
    name = scope.instanceName;
    requires = [ self.statefulset ];
    spec.ports = [{ port = 5432; }];
  };

  main = self.service;
}
```

### 2.2 What the Consumer Sees

The evaluator transforms the package's `self` into a consumer-facing view:

```nix
postgres.secrets.credentials           # folder: contracted, auto-exposed
postgres.secrets.credentials.out.keyRef "password"

postgres.main                          # the primary resource
postgres.main.out.name                 # resource-level out
postgres.main.out.fqdn

postgres.name                          # auto-copied from main.out
postgres.fqdn                          # auto-copied from main.out
postgres.selector                      # auto-copied from main.out

postgres.raw.statefulset               # everything else — "at your own risk"
postgres.raw.service
postgres.raw.secrets.credentials       # folders are also in raw (same ref)
postgres.raw.main                      # main is also in raw
```

### 2.3 The Transform

The evaluator applies this transform after the fixpoint resolves:

```nix
mkPackageView = self: let
  # Well-known folder keys
  folderKeys = [ "secrets" "crds" ];
  # System keys (not in raw, not consumer-facing)
  systemKeys = [ "meta" ];
  # Special keys
  specialKeys = [ "main" ];

  folders = lib.genAttrs folderKeys (k: self.${k} or {});
  meta = self.meta or {};
  main = self.main;
in
  # Contracted folders
  folders
  # main
  // { inherit main; }
  # Auto-copied from main.out (name, fqdn, selector, etc.)
  // (main.out or {})
  # Raw — the complete self, always available
  // { raw = self; };
```

Key properties:

- **`raw = self`** — nothing is removed, nothing is hidden. `raw` is the full
  `self` attrset. Folders and `raw` contain the same objects (same Nix thunks),
  just accessed via different paths.

- **No double-counting.** Resource collection walks `raw` (which is `self`).
  Folders are purely consumer-facing views, not a separate resource store.

- **`meta` is excluded from the consumer view.** It's evaluator/system metadata,
  not something consumers reference.

---

## 3. Folder Definitions

### 3.1 `secrets`

Secret resources this package produces and exposes for DI consumption.

```nix
secrets.credentials = scope.mkSecret { ... };
secrets.apiKey = scope.mkSecret { ... };
```

Consumers access: `postgres.secrets.credentials.out.keyRef "password"`

A package that consumes a secret through DI override places it here too:

```nix
{ credentials ? null }:
self: {
  secrets.credentials = if credentials != null
    then credentials
    else scope.mkSecret { ... };
}
```

The evaluator can validate that everything under `secrets` is actually a
secret resource (created by `mkSecret` or `mkSecretRef`).

### 3.2 `crds`

CRD resources and CRD refs this package owns.

```nix
# cert-manager today:
crdCertificates = mkCRD { ... };
crdCertificateRequests = mkCRD { ... };

# with folders:
crds.certificates = mkCRD { ... };
crds.certificateRequests = mkCRD { ... };
```

Consumers access: `certManager.crds.certificates.out.bind scope`

This is already partially the pattern — CRDs expose builders on their `out`
(doc 21). Folders just make the grouping explicit and auto-exposed.

### 3.3 `main`

The primary resource. Not a folder — a single resource that represents the
package's entry point. Its `out` properties (name, fqdn, selector, etc.) are
auto-copied to the package's top level.

```nix
main = self.service;

# Consumer can write:
postgres.fqdn     # instead of postgres.main.out.fqdn
postgres.name      # instead of postgres.main.out.name
```

### 3.4 `meta`

Package metadata consumed by the evaluator and DI system, not by consumers.

```nix
meta = {
  lifecycle = "stateful";      # warn before deleting PVCs
  scope = "namespace";         # prevent cross-namespace DI resolution
  aliases = [ "database" ];    # DI alias resolution
};
```

---

## 4. Everything Else → `raw`

Resources not placed in a folder live directly on `self`:

```nix
self: {
  secrets.credentials = scope.mkSecret { ... };  # → folder
  crds.myCrd = scope.mkCRD { ... };               # → folder

  deployment = scope.mkResource { ... };           # → raw.deployment
  service = scope.mkResource { ... };              # → raw.service
  configMap = scope.mkResource { ... };            # → raw.configMap

  main = self.service;
}
```

The consumer sees `postgres.raw.deployment`, `postgres.raw.configMap`, etc.
These are accessible but **not part of the package's contract**. The package
author can rename, restructure, or remove them without it being a breaking
change for consumers.

### 4.1 The `raw` Escape Hatch

`raw` exists because real-world usage is messy. Sometimes a consumer needs
to reference an internal resource — maybe for a ServiceMonitor selector,
maybe for a debugging tool, maybe for a one-off integration that doesn't
warrant a formal contract.

```nix
# Consumer reaching into postgres internals — works, but not contracted
postgres.raw.statefulset.out.name
```

The package author makes no guarantees about `raw`. It's the "you can look
under the hood, but don't blame me if it changes" boundary.

### 4.2 Should `raw` Access Warn?

Options:

- **Silent.** `raw` is just an attrset. No ceremony. Simple.
- **Trace warning.** `builtins.trace "accessing non-contracted resource
  postgres.raw.statefulset"`. Makes the boundary visible in build logs.
- **Opt-in warning.** Package author marks specific resources as
  `internal = true` to trigger warnings.

**Recommendation:** Silent. The structural separation (folder vs raw) is
sufficient signal. Warnings in build logs are noise. If a consumer depends on
`raw`, they accept the risk — that's the point of the escape hatch.

---

## 5. What This Looks Like for Existing Packages

### 5.1 cert-manager — CRD-heavy package

Before:
```nix
self: {
  crdCertificates = mkCRD { ... };
  crdCertificateRequests = mkCRD { ... };
  crdChallenges = mkCRD { ... };
  crdClusterIssuers = mkCRD { ... };
  crdIssuers = mkCRD { ... };
  crdOrders = mkCRD { ... };

  controllerServiceAccount = scope.mkResource { ... };
  controllerDeployment = scope.mkResource { ... };
  webhookDeployment = scope.mkResource { ... };
  # ... 30+ more resources ...

  main = { resource = self.controllerDeployment; requires = [ ... ]; };
}
```

After:
```nix
self: {
  crds = {
    certificates = mkCRD { ... };
    certificateRequests = mkCRD { ... };
    challenges = mkCRD { ... };
    clusterIssuers = mkCRD { ... };
    issuers = mkCRD { ... };
    orders = mkCRD { ... };
  };

  controllerServiceAccount = scope.mkResource { ... };
  controllerDeployment = scope.mkResource { ... };
  webhookDeployment = scope.mkResource { ... };
  # ... 30+ more resources — all end up in raw ...

  main = { resource = self.controllerDeployment; requires = [ ... ]; };
}
```

Consumer:
```nix
# Before: certManager.crdCertificates.out.bind scope
# After:  certManager.crds.certificates.out.bind scope
```

The CRDs are now structurally grouped and auto-exposed. The 30+ internal
resources (deployments, services, RBAC) are in `raw` — accessible but not
part of the contract.

### 5.2 immich — consumer with optional deps

Before:
```nix
self: {
  deployment = scope.mkDeployment { ... };
  service = scope.mkResource { ... };
  ingress = if config.ingress.enabled then ... else null;
  serviceMonitor = if config.metrics.enabled then ... else null;
  configMap = if hasConfig then ... else null;
  main = self.service;
}
```

After (no change needed — immich has no folders to declare):
```nix
self: {
  deployment = scope.mkDeployment { ... };
  service = scope.mkResource { ... };
  ingress = if config.ingress.enabled then ... else null;
  serviceMonitor = if config.metrics.enabled then ... else null;
  configMap = if hasConfig then ... else null;
  main = self.service;
}
```

Immich doesn't produce secrets or CRDs, so it has no folders. Everything
lives in `raw`. The consumer view just has `main` + `main.out` auto-copied.

If immich later adds a secret (e.g., JWT signing key):
```nix
self: {
  secrets.jwtKey = scope.mkSecret {
    keys = [ "secret" ];
    generate = { secret = { type = "random"; length = 64; }; };
  };

  # ... rest unchanged ...
}
```

Now `immich.secrets.jwtKey` is auto-exposed. No other changes needed.

### 5.3 postgres with secrets — the full pattern

```nix
{ scope, config, storage, credentials ? null }:

self: {
  meta.lifecycle = "stateful";

  secrets.credentials = if credentials != null
    then credentials
    else scope.mkSecret {
      name = "${scope.instanceName}-credentials";
      keys = [ "username" "password" "host" "port" ];
      generate = {
        password = { type = "random"; length = 32; };
        username = { type = "fixed"; value = "postgres"; };
      };
    };

  dataPvc = scope.mkResource {
    kind = "PersistentVolumeClaim";
    name = "${scope.instanceName}-data";
    spec.storageClassName = "${storage.main}";
    spec.resources.requests.storage = config.dataSize;
  };

  statefulset = scope.mkResource {
    kind = "StatefulSet";
    name = scope.instanceName;
    spec.template.spec.containers = [{
      name = "postgres";
      image = config.image;
      env = [
        (self.secrets.credentials.out.keyRef "password"
          // { name = "POSTGRES_PASSWORD"; })
        (self.secrets.credentials.out.keyRef "username"
          // { name = "POSTGRES_USER"; })
      ];
      volumeMounts = [{ name = "data"; mountPath = "/var/lib/postgresql/data"; }];
    }];
    spec.template.spec.volumes = [{
      name = "data";
      persistentVolumeClaim.claimName = "${self.dataPvc}";
    }];
  };

  service = scope.mkResource {
    kind = "Service";
    name = scope.instanceName;
    requires = [ self.statefulset ];
    spec.ports = [{ port = 5432; }];
  };

  main = self.service;
}
```

Consumer:
```nix
{ postgres, ... }:
env = [
  # Secret through folder — contracted
  (postgres.secrets.credentials.out.keyRef "password" // { name = "DB_PASSWORD"; })

  # main.out auto-copied to top level
  { name = "DB_HOST"; value = postgres.fqdn; }
];
```

---

## 6. NixOS Module Analogy

This design is inspired by how NixOS modules work. In NixOS:

- Modules declare **options** (the public interface)
- Modules set **config** (contributions to a shared tree)
- `evalModules` **merges** all contributions and validates types

The analogy in kix:

| NixOS | kix packages |
|---|---|
| `options` declaration | Folder keys (`secrets`, `crds`) — structural contract |
| `config` values | Resources on `self` — the package's contribution |
| `evalModules` merge | Evaluator auto-exposes folders, sweeps rest to `raw` |
| Module doesn't call `systemd.addService()` | Package doesn't manually wire `out` |

The key insight from NixOS: **the author declares intent through structure,
the system handles plumbing.** A NixOS module sets
`config.systemd.services.nginx = { ... }` and the systemd module picks it up.
A kix package sets `secrets.credentials = scope.mkSecret { ... }` and the
evaluator exposes it.

---

## 7. Resource Collection — No Double-Counting

The evaluator collects resources for the DAG from `self` (which is the same
object as `raw`). Folders are **views**, not separate stores.

```
self = {
  secrets.credentials = <secret-resource>;  # a resource
  deployment = <resource>;                   # a resource
  service = <resource>;                      # a resource
  main = <resource>;                         # a resource (or resource wrapper)
  meta = { lifecycle = "stateful"; };        # NOT a resource
};

# Resource collection walks self, finds resources by _type:
# - self.secrets.credentials  → collected (it's a resource)
# - self.deployment           → collected
# - self.service              → collected
# - self.main                 → collected (or extracted from wrapper)
# - self.meta                 → skipped (not a resource)
```

The folders don't create duplicates because `raw.secrets.credentials` and
`secrets.credentials` are the same Nix thunk. The resource walker sees each
resource exactly once.

---

## 8. Adding New Folders

The folder system is extensible. When a new category earns structured
treatment, the evaluator learns a new key:

| Candidate | Use case | Readiness |
|---|---|---|
| `secrets` | Secret resources (doc 22) | Ready — active design |
| `crds` | CRD resources and refs (doc 21) | Ready — existing pattern |
| `services` | Named service endpoints | Maybe — most packages have one (`main`) |
| `configmaps` | Exposed ConfigMaps | Unlikely — rarely part of DI contract |
| `builders` | Exposed builder functions (withCert, mkCertificate) | Worth exploring |

**Criteria for adding a folder:**

1. Multiple packages produce this type of resource
2. Consumers commonly need to access it through DI
3. The grouping carries information beyond the K8s `kind` (it signals intent:
   "this is part of my public contract")

Start with `secrets` and `crds`. Add more only when there's concrete demand.

### 8.1 `builders` as a Folder?

Packages like cluster-issuers expose builder functions (`withCert`,
`mkCertificate`). These aren't resources — they're functions. But they're
part of the DI contract.

```nix
self: {
  crds.clusterIssuer = scope.mkCRD { ... };

  builders.withCert = cert: resource: ...;
  builders.mkCertificate = { name, hosts, ... }: ...;

  main = self.crds.clusterIssuer;
}
```

Consumer: `clusterIssuer.builders.mkCertificate { ... }`

This is interesting because it separates resources from functions in a
self-documenting way. But it's also extra structure — today these live on
`out` and that works fine. Defer until there's a clear pain point.

---

## 9. Migration Path

The transform is backwards-compatible. Existing packages that don't use
folders get everything in `raw`, plus `main` and `main.out` auto-copied.
The consumer view is strictly additive:

```
Before: postgres.out.name, postgres.out.fqdn
After:  postgres.name, postgres.fqdn, postgres.raw.*, postgres.main.out.*
```

Migration is incremental:

1. **Phase 1:** Evaluator learns folders, builds `raw` from `self`. Existing
   packages unchanged — their resources land in `raw`.
2. **Phase 2:** Package authors move CRDs into `crds = { ... }` and secrets
   into `secrets = { ... }` as they touch packages. No rush.
3. **Phase 3:** Deprecate manual `out` wiring on packages (resource-level
   `out` stays — it's auto-derived).

---

## 10. Open Questions

### 10.1 Naming Collisions Between `main.out` and Folders

If `main.out` has a key called `secrets` and the package also has a `secrets`
folder, the auto-copy collides. Resolution options:

- **Folders win.** Auto-copied `main.out` keys that collide with folder names
  are skipped. This is safe because the folder is more specific.
- **Error.** Throw at eval time if there's a collision. Strict but catches
  accidental naming conflicts.

**Recommendation:** Folders win, silently. The collision is unlikely in practice
(a resource's `out` wouldn't normally have a `secrets` field), and the folder
is always the more intentional declaration.

### 10.2 Should Folder Contents Be Type-Checked?

Should the evaluator validate that everything under `secrets` is actually a
secret resource? Options:

- **No validation.** Folders are conventional, not enforced. Simple.
- **Type check.** `secrets` must contain only `mkSecret`/`mkSecretRef` results.
  `crds` must contain only `mkCRD`/`mkCRDRef` results. Catches mistakes.
- **Warning.** Non-matching types trigger `builtins.trace` warnings but don't
  fail the build.

**Recommendation:** Type check. The evaluator already knows resource types
via `_type` tags. Catching a Deployment accidentally placed under `secrets`
is worth the minimal implementation cost.

### 10.3 Nested Folders?

Should folders support nesting? E.g.:

```nix
secrets.database.credentials = scope.mkSecret { ... };
secrets.database.replication = scope.mkSecret { ... };
secrets.external.apiKey = scope.mkSecret { ... };
```

This is valid Nix — it's just nested attrsets. The evaluator would need to
walk recursively to find resources. **Recommendation:** Support it — the
resource walker already does recursive traversal. Let package authors organize
as they see fit.

### 10.4 How Does This Interact with the Module System?

If kix moves to a NixOS-style module system (docs 12-20), folders could
become **option declarations** — the evaluator's folder recognition would be
replaced by module option types:

```nix
options.secrets = lib.mkOption {
  type = lib.types.attrsOf lib.types.secretResource;
  default = {};
};
```

This is a natural evolution, not a conflict. The folder system is a stepping
stone toward full module-system integration. The consumer-facing API
(`postgres.secrets.credentials`) stays the same either way.
