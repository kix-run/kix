# 62a — Exposure as a Composable Build Entry

**Status:** Implemented (Phase 0–3)
**Related:** `62_exposure_compilation.md` (predecessor — rejected approaches require app dev to know infrastructure deps), `42_dep_config_injection.md` (config push from consumer to dep), `29_compiler-design.md` (§6 persona-driven intent model)

---

## 1. The Real Problem (Reframed)

Doc 62 analyzed the exposure boilerplate and proposed helpers to reduce it. But it missed the core issue: **the app developer shouldn't need to know that `ingressNginx` and `clusterIssuer` exist.**

Today, an app developer writing an immich package must:
1. Declare `ingressNginx ? null` and `clusterIssuer ? null` as optional deps
2. Compute `hasIngress`, `hasTls` gate variables
3. Thread `ingressNginx.out.ingressClassName` into the ingress spec
4. Apply `clusterIssuer.out.withCert` as a pipe transformer
5. Construct the TLS block with correct `secretName`

This is infrastructure wiring leaking into app-level code. The compiler design doc (§6) is explicit about this:

> **App Developer** declares: "I have a web service that listens on port 8080."
> Does NOT care about: RBAC rules, NetworkPolicy details, **Ingress annotations, certificate management.**

The app developer's intent is: **"this service should be reachable from outside the cluster."** Everything else — the ingress controller, TLS, annotations — is the platform engineer's concern.

---

## 2. The Mechanism: Build Entries as Composable Layers

kix already has the exact mechanism needed. `build` can be a **list of functions**, each called with `{ self, config, clusterConfig, scope, lib, kix, ...deps }`, their results merged via `//` in a fixpoint:

```nix
# cert-manager uses this today:
build = [
  ./crds.nix
  ./controller.nix
  ./webhook.nix
  ./cainjector.nix
  ({ self, ... }: { root = { resource = self.controllerDeployment; ... }; })
];
```

Each entry sees all parts from all other entries via `self`. Each entry can declare its own DI deps via function argument introspection. **This means a build entry can be a reusable, configurable module that adds resources to any package.**

---

## 3. Proposal: `kix.expose` as a Build Entry

### 3.1 The Simplest Case

An app developer writes:

```nix
{ scope, lib, kix }:
{
  meta = { ... };
  options = {
    image = lib.mkOption { ... };
    ingress.host = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
    ingress.annotations = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; };
  };

  build = [
    # The app — knows nothing about infrastructure
    ({ self, config, scope, kix, ... }:
    {
      deployment = {
        name = "myapp";
        spec.template.spec.containers = [{
          name = "myapp";
          image = "${config.image.repository}:${config.image.tag}";
          ports = [ (kix.port "http" 8080) ];
        }];
      } |> scope.mkDeployment;

      service = self.deployment
        |> kix.service.fromWorkload { name = "myapp"; }
        |> scope.mkResource;

      root = self.service;
    })

    # Exposure — a reusable build entry from kix
    (kix.expose {
      service = "service";            # name of the part to expose (resolved from self)
      hostOption = "ingress.host";    # path into config for the host
      annotationsOption = "ingress.annotations";
    })
  ];
}
```

The `kix.expose` function returns a build entry (a function) that:
1. Declares `ingressNginx ? null` and `clusterIssuer ? null` as its DI deps (via function args)
2. Reads `self.service` to get the service resource
3. Reads `config.ingress.host` for the host (with cluster.domain fallback)
4. Creates the Ingress resource (if ingressNginx is present)
5. Applies TLS (if clusterIssuer is present)
6. Adds the ingress to `self` as `self.ingress`

### 3.2 What `kix.expose` Returns

```nix
# In lib/compose.nix (or a new lib/expose.nix):
expose = {
  service,                          # string: part name in self, e.g. "service"
  hostOption ? "ingress.host",      # string: config path for host
  annotationsOption ? "ingress.annotations",  # string: config path for annotations
  partName ? "ingress",             # string: name of the generated part in self
  defaultAnnotations ? {},          # attrset: package-level default annotations
  port ? null,                      # int or null: override auto-derived port
  tlsSecretName ? null,             # string or null: override auto-derived name
}:
# Returns a build entry function:
{ self, config, clusterConfig, scope, lib, kix,
  ingressNginx ? null, clusterIssuer ? null, ... }:
let
  svc = self.${service};

  # Host resolution: config > cluster.domain > null
  clusterDomain = clusterConfig.cluster.domain or null;
  configHost = lib.attrByPath (lib.splitString "." hostOption) null config;
  effectiveHost =
    if configHost != null then configHost
    else if clusterDomain != null then "${scope.instanceName}.${clusterDomain}"
    else null;

  hasIngress = ingressNginx != null && effectiveHost != null;
  hasTls = hasIngress && clusterIssuer != null;

  configAnnotations = lib.attrByPath (lib.splitString "." annotationsOption) {} config;
in
{
  ${partName} = if hasIngress then
    svc
    |> kix.ingress.fromService {
      name = scope.instanceName;
      host = effectiveHost;
      className = ingressNginx.out.ingressClassName;
      tls = lib.optional hasTls {
        hosts = [ effectiveHost ];
        secretName =
          if tlsSecretName != null then tlsSecretName
          else "${scope.instanceName}-tls";
      };
      annotations = defaultAnnotations // configAnnotations;
    }
    |> (if hasTls then clusterIssuer.out.withCert else lib.id)
    |> scope.mkResource
  else null;
};
```

### 3.3 DI Resolution: How Dependencies Work

This is the crucial bit. `instance.nix` already discovers deps by introspecting **all** build entries:

```nix
# instance.nix line 162-166:
rawBuildEntries =
  if builtins.isList raw.build then
    map (entry: if builtins.isPath entry then import entry else entry) raw.build
  else
    [ raw.build ];
```

And `discoverBuildDeps` (in resolve.nix) introspects the function args of the build function. But today it only looks at the **top-level** build function, not individual entries in a list.

**Change needed:** `discoverBuildDeps` must discover deps from **all** build entries in the list, not just the first/only one. Then `ingressNginx ? null` declared by the `kix.expose` entry gets discovered, resolved, and injected automatically.

Let me verify the current behavior:

```nix
# resolve.nix — discoverBuildDeps:
discoverBuildDeps = buildFn: ...
```

If `build` is a list, `callPackagePhase1` returns `{ build = raw.build }` — the list itself. Then `discoverBuildDeps` is called on `raw.build`, which is a list, not a function. **This needs to handle lists.**

Actually, looking more carefully at the code flow: `callPackagePhase1` calls the package function to get `{ meta, options, deps?, build }`. The `build` value is the raw list. Then `discoverBuildDeps` is called on that value. If it only handles single functions, it would need to be extended to union deps from all list entries.

**This is a prerequisite change**, but a clean one: `discoverBuildDeps` becomes:

```nix
discoverBuildDeps = build:
  if builtins.isList build then
    builtins.foldl' (acc: entry:
      let entryDeps = discoverBuildDeps (if builtins.isPath entry then import entry else entry);
      in acc // entryDeps
    ) {} build
  else if builtins.isFunction build then
    # existing logic: introspect function args
    ...
  else {};
```

---

## 4. What This Enables

### 4.1 App Developer Experience

The app developer writes their service. They add `kix.expose { service = "service"; }` to their build list. Done. They never import, reference, or think about ingress controllers or certificate managers.

If the cluster has `ingressNginx` and `clusterIssuer` instances → the app gets an ingress with TLS.
If the cluster has only `ingressNginx` → the app gets an ingress without TLS.
If the cluster has neither → no ingress. The service is internal-only.

The cluster operator controls this by what infrastructure packages are in the cluster — not by configuring each app.

### 4.2 Platform Engineer Experience

The platform engineer can customize exposure cluster-wide via `globalPartsOverlays`:

```nix
# "All exposed services get rate limiting annotations"
globalPartsOverlays = [
  (scope: self: base:
    if base ? ingress && base.ingress != null then {
      ingress = base.ingress // {
        # This doesn't work — ingress is already a sealed resource.
        # See §6 for the overlay timing problem.
      };
    } else {})
];
```

Or, more powerfully, they could provide their own exposure entry that replaces the default one. See §5.3.

### 4.3 Multiple Services

A package with multiple exposed services:

```nix
build = [
  # App logic
  ({ self, config, scope, kix, ... }: {
    apiService = self.apiDeployment
      |> kix.service.fromWorkload { name = "api"; }
      |> scope.mkResource;

    adminService = self.adminDeployment
      |> kix.service.fromWorkload { name = "admin"; }
      |> scope.mkResource;

    root = self.apiService;
  })

  # Expose both
  (kix.expose {
    service = "apiService";
    partName = "apiIngress";
    hostOption = "api.host";
    defaultAnnotations = { "nginx.ingress.kubernetes.io/proxy-body-size" = "0"; };
  })
  (kix.expose {
    service = "adminService";
    partName = "adminIngress";
    hostOption = "admin.host";
  })
];
```

Each `kix.expose` entry adds a distinct part. The DI deps (`ingressNginx`, `clusterIssuer`) are discovered once (deduped across entries) and resolved once.

### 4.4 Monitoring, Backup — Same Pattern

The build-entry pattern generalizes to other cross-cutting concerns:

```nix
build = [
  ./app.nix

  (kix.expose { service = "service"; })

  (kix.monitor {
    service = "service";
    endpoints = [{ port = "metrics"; }];
  })

  (kix.backup {
    resources = [ "dataVolume" ];
  })
];
```

Each entry declares its own DI deps (`prometheus ? null`, `velero ? null`), creates resources only when the dep is present, and adds parts to `self`. The app developer lists *capabilities they want*; the platform decides whether to provide them.

---

## 5. Design Questions

### 5.1 `service` as String vs Reference

The proposal uses `service = "service"` (a string key into `self`). The alternative is `service = self.service` — but this doesn't work because `kix.expose { ... }` is called *outside* the fixpoint (at package definition time), before `self` exists. The string is resolved inside the build entry where `self` is available.

This is the same pattern as `kix.mount.pvc storage { ... }` where `storage` is a DI dep resolved at build time, not at definition time.

**Downside:** If the part name is wrong (typo: `"servce"` instead of `"service"`), the error only surfaces when the fixpoint evaluates `self.servce` → attribute missing. This is a runtime error, not a definition-time error.

**Mitigation:** The error message from Nix is clear: "attribute 'servce' missing in attribute set at ...". And the entry is right next to the part definition in the same file.

### 5.2 Option Paths as Strings

`hostOption = "ingress.host"` uses a dotted string path into `config`. This works via `lib.attrByPath (lib.splitString "." path) null config`. It's dynamic and stringly-typed.

**Alternative:** Accept a function:

```nix
kix.expose {
  service = "service";
  host = config: config.ingress.host;
}
```

But this doesn't work either — `config` isn't available at package definition time. The string path is the pragmatic choice. We could add a check that the path exists in the package's `options` declaration, but that's a phase-2 nicety.

**Simpler alternative:** Don't use option paths at all. Just let the expose entry read a fixed config shape:

```nix
# kix.expose always reads config.expose.host, config.expose.annotations
# The package declares:
options.expose = kix.options.expose;  # shared option definition
```

This is more opinionated but eliminates the stringly-typed path problem. See §5.5.

### 5.3 Overriding the Default Exposure

What if a package needs non-standard exposure (harbor's multi-path routing)? Two options:

**A. Don't use `kix.expose`.** Write the ingress manually, with `ingressNginx ? null` in the package's own build function. `kix.expose` is for the 80% case.

**B. Provide a custom build entry that replaces the generated one.** Since build entries merge with `//`, a later entry wins:

```nix
build = [
  ./app.nix
  (kix.expose { service = "coreService"; partName = "ingress"; })

  # Override: custom multi-path ingress
  ({ self, config, scope, ingressNginx ? null, clusterIssuer ? null, ... }:
    if ingressNginx == null then {}
    else {
      # This `ingress` part replaces the one from kix.expose
      ingress = { apiVersion = "networking.k8s.io/v1"; kind = "Ingress"; ... }
        |> scope.mkResource;
    })
];
```

The later entry's `ingress` key wins in the `//` merge, replacing the generated one. This is explicit and visible.

### 5.4 Dep Discovery from Build Lists

As noted in §3.3, `discoverBuildDeps` needs to handle list-shaped builds. This is the one code change that goes beyond compose.nix:

```
resolve.nix: discoverBuildDeps must union deps from all list entries
```

This is a clean extension. The union means: if two entries both declare `ingressNginx ? null`, it's discovered once (as optional). If one declares `postgres` (required) and another declares `ingressNginx ? null` (optional), both are in the dep set with their correct optionality.

**Edge case:** Two entries declare the same dep with different optionality (one required, one optional). The required one should win — if *any* entry requires a dep, it's required. This matches `//` semantics: `{ postgres = { optional = false; } } // { postgres = { optional = true; } }` → the second wins, which is wrong. Need explicit merge: required wins over optional.

### 5.5 Standardized `expose` Options

Instead of configurable option paths, provide a standard option set:

```nix
# In kixlib:
kix.options.expose = {
  host = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Ingress hostname. Null = auto-derive from cluster.domain.";
  };
  annotations = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = "Extra ingress annotations.";
  };
};

# Package:
options.expose = kix.options.expose;

# kix.expose reads config.expose.host, config.expose.annotations
# No stringly-typed paths needed.
```

**Tradeoff:** Packages that currently use `config.ingress.host` would need to migrate to `config.expose.host`. But this is a naming convention change, not a structural one.

**Or:** Keep `ingress` as the conventional name and just standardize the shape:

```nix
kix.options.ingress = {
  host = lib.mkOption { ... };
  annotations = lib.mkOption { ... };
};
```

`kix.expose` reads `config.ingress.host` by default. No option path configuration needed — just a convention.

### 5.6 The `root` Question

When an ingress exists, should it become the package's root? Today, most packages use the service as root:

```nix
root = self.service;
```

If the ingress is the outermost resource (the "entry point"), it could be the root. But this changes the package's identity hash whenever ingress config changes — even if the service itself is unchanged.

**Recommendation:** Keep service as root. The ingress is a derived resource — it depends on the service, not the other way around. The `kix.expose` entry should add `requires` to ensure the ingress is in the forward closure:

```nix
# kix.expose output includes root adjustment:
{
  ${partName} = ...the ingress resource...;

  # Patch root to include ingress in forward closure
  root = if base.root ? resource then
    base.root // { requires = (base.root.requires or []) ++ [ self.${partName} ]; }
  else
    { resource = base.root; requires = [ self.${partName} ]; };
}
```

Wait — this is tricky. The build entry's output merges with `//` into `self`. If the app's build entry sets `root = self.service` and the expose entry sets `root = { resource = self.service; requires = [ self.ingress ]; }`, the expose entry's `root` wins because it comes later in the list.

This is actually the right behavior — the expose entry wraps the root to include the ingress in the closure. If no expose entry is present, the original root stands.

**But:** This means the expose entry must know the app's root resource, or must wrap whatever root the app set. It should read `self.root` (from the app entry) and augment it. Since all entries share the fixpoint, `self.root` is the merged result — but entries are merged left-to-right with `//`, so the last entry's `root` wins.

A cleaner approach: the expose entry adds the ingress to `requires` on the service resource instead:

Actually, the ingress already references `self.service.out.name` in its backend, which creates a store-path dependency. The ingress is in the forward closure via context tracking. No explicit `requires` needed.

The *inverse* is the question: is the ingress reachable from root? If `root = self.service`, the forward closure walks from the service. The ingress references the service, but the service doesn't reference the ingress — so the ingress is NOT in the forward closure. It would be flagged as orphaned.

**Solution:** The expose entry adds the ingress to `root.requires`:

```nix
{
  ${partName} = if hasIngress then ...the ingress... else null;

  # If we created an ingress, add it to root's package-level requires
  root =
    let baseRoot = self.root or (throw "kix.expose: package must define root before expose entry");
    in if hasIngress && self.${partName} != null then
      (if baseRoot ? resource then
        baseRoot // { requires = (baseRoot.requires or []) ++ [ self.${partName} ]; }
      else
        { resource = baseRoot; requires = [ self.${partName} ]; })
    else baseRoot;
}
```

This works because the expose entry is later in the build list, so its `root` wins in the `//` merge. It wraps the app's root to include the ingress.

### 5.7 Overlay Timing: Pre-Seal vs Post-Seal

`globalPartsOverlays` run after all build entries are merged (instance.nix line 192). At that point, resources like the ingress are already sealed (they've been through `scope.mkResource`). You can't modify a sealed resource's annotations.

This means platform-engineer customization of exposure must happen *before* sealing — i.e., inside the build entry itself or via config injection.

**Config injection (doc 42) is the right channel.** If a platform module wants all ingresses to have a rate-limit annotation:

```nix
# Platform module in cluster definition:
globalPartsOverlays = [ ... ]; # Too late — resources are sealed

# Instead, use config injection or a shared config default:
# (This is a design gap — config injection works per-dep, not per-package)
```

Actually, the cleaner path: **default annotations on `kix.expose`** can be set at the cluster level via the config system:

```nix
# Package options (via kix.options.ingress):
options.ingress.annotations = lib.mkOption { default = {}; };

# Cluster module:
instances.apps.myapp.config.ingress.annotations = {
  "nginx.ingress.kubernetes.io/rate-limit" = "10";
};
```

Or even:

```nix
# Global config that applies to all instances:
# (Not currently a feature, but could be via a module that iterates instances)
```

The platform customization story needs more thought — it's related to the "security defaults via mkDefault" roadmap item. Defer for now.

---

## 6. Concrete Example: Immich, Rewritten

### Before (current, ~25 lines of ingress wiring):

```nix
{ scope, lib, kix }:
{
  options = {
    ingress = lib.mkOption {
      type = lib.types.anything;
      default = { host = null; annotations = {}; };
    };
    # ...
  };

  build = { self, config, clusterConfig, valkey, postgres, storage,
            machineLearning ? null, ingressNginx ? null, clusterIssuer ? null,
            prometheus ? null, ... }:
  let
    clusterDomain = clusterConfig.cluster.domain or null;
    ingressHost = if config.ingress.host != null then config.ingress.host
      else if clusterDomain != null then "${name}.${clusterDomain}" else null;
    hasIngress = ingressNginx != null && ingressHost != null;
    hasTls = hasIngress && clusterIssuer != null;
  in {
    # ... deployment, service ...

    ingress = if hasIngress then
      self.service |> kix.ingress.fromService {
        inherit name;
        host = ingressHost;
        className = ingressNginx.out.ingressClassName;
        tls = lib.optional hasTls { hosts = [ ingressHost ]; secretName = "${name}-tls"; };
        annotations = { "nginx.ingress.kubernetes.io/proxy-body-size" = "0"; }
          // config.ingress.annotations;
      }
      |> (if hasTls then clusterIssuer.out.withCert else lib.id)
      |> scope.mkResource
    else null;

    root = self.service;
  };
}
```

### After (with kix.expose):

```nix
{ scope, lib, kix }:
{
  options = {
    ingress = kix.options.ingress;  # { host, annotations }
    # ...
  };

  build = [
    # App logic — no infrastructure deps
    ({ self, config, clusterConfig, scope, kix,
       valkey, postgres, storage, machineLearning ? null, prometheus ? null, ... }:
    {
      # ... deployment ...

      service = self.deployment
        |> kix.service.fromWorkload { name = "${name}-server"; }
        |> scope.mkResource;

      # ... serviceMonitor ...

      root = self.service;
    })

    # Exposure — one line
    (kix.expose {
      service = "service";
      defaultAnnotations = { "nginx.ingress.kubernetes.io/proxy-body-size" = "0"; };
    })
  ];
}
```

The app's build function no longer declares `ingressNginx ? null` or `clusterIssuer ? null`. Those deps are on the `kix.expose` entry. The package author writes their app and says "expose it." The platform decides how.

---

## 7. Implementation Plan

### Phase 0: Extend `discoverBuildDeps` for list builds

`resolve.nix`: handle `build = [ fn1 fn2 ... ]` by discovering deps from all entries and merging. Required dep wins over optional.

### Phase 1: `kix.expose` build entry

`lib/compose.nix` (or `lib/expose.nix`): the `expose` function that returns a build entry. Reads `config.ingress.host` (convention), handles host resolution, gates on DI deps, creates Ingress, applies TLS, wraps root.

### Phase 2: `kix.options.ingress` shared option

Standardize the `{ host, annotations }` option shape. Optional — packages can keep their own option declarations.

### Phase 3: Migrate simple packages

Mechanical migration of n8n, vaultwarden, metabase, filebrowser (the identical-pattern packages). Keep immich for last — it has custom annotations and is the reference implementation.

### Phase 4: Explore `kix.monitor`, `kix.backup`

Same pattern for monitoring (ServiceMonitor when prometheus is present) and backup (Velero annotations when velero is present). Each is a build entry that declares its own DI deps.

---

## 8. Open Questions

### 8.1 How does `discoverBuildDeps` handle nested builds today?

`callPackagePhase1` calls the package function to get `{ meta, options, deps?, build }`. If `build` is a list, does `discoverBuildDeps` already handle it? If not, this is the first thing to verify/implement.

### 8.2 Should `kix.expose` be a function or a module?

The proposal makes it a function returning a build entry. An alternative: make it a NixOS module that packages import:

```nix
# Package imports kix.modules.expose:
modules = [ kix.modules.expose ];
options.expose.host = ...;
```

But packages don't use the module system internally (they use `{ meta, options, build }`). This would be a bigger structural change. The build-entry approach fits the current architecture.

### 8.3 What if a package has no service but wants exposure?

Edge case: a package that creates a raw Service (not via `fromWorkload`) or where the "service" is named something non-obvious. The `service = "serviceName"` parameter handles this — it's just the key in `self`. If the package has `self.coreService`, use `service = "coreService"`.

### 8.4 Config convention: `ingress` vs `expose`

Should the config path be `config.ingress.*` (matches current packages) or `config.expose.*` (matches the concept)?

`ingress` is K8s-specific. `expose` is intent-based. If kix ever supports non-ingress exposure (e.g., Gateway API, Cloudflare Tunnel), `expose` ages better.

But migration cost from `config.ingress` to `config.expose` across 8 packages is real. And `ingress` is what K8s users expect.

**Lean:** Keep `config.ingress` as the default convention. `kix.expose` reads it by default. If a package uses a different path, pass `hostOption`.

### 8.5 Can the expose entry modify `root`?

As discussed in §5.6, the expose entry needs to wrap `root` to include the ingress in `requires`. Since build entries merge with `//` (last wins), the expose entry's `root` replaces the app's.

**Risk:** If the app author puts `root` in the app entry AND the expose entry emits `root`, the expose version wins silently. This could be surprising.

**Mitigation:** Document that `kix.expose` wraps `root`. Or: don't modify `root` at all — rely on the inverse-dep detection (`instance.nix` line 302-322) to include the ingress in the PI closure. The ingress references `self.service.out.name`, so it references a resource in the forward closure — it would be detected as an inverse dep.

Actually, looking at the code: inverse deps are resources NOT in the forward closure whose manifest references a resource IN the forward closure. An ingress referencing the service would be exactly this. So the ingress would be included as an inverse dep on the PackageInstance without any `root` modification.

**This means we don't need to touch `root` at all.** The existing inverse-dep mechanism handles it.

### 8.6 Multi-build dep discovery: precedence for optionality

If entry A declares `postgres` (required) and entry B declares `postgres ? null` (optional), which wins?

For correctness: required must win. If *any* entry needs the dep, it's required. The merge should be: `optional = all entries agree it's optional`.

This needs explicit handling in the dep discovery merge — `//` alone doesn't do it right because the second entry's `{ optional = true }` would overwrite the first's `{ optional = false }`.
