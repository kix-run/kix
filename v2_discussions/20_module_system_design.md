# 20 — Module System Design

**Status:** Design — supersedes docs 12–18 with refinements from contrastive analysis (doc 19)
**Predecessors:** 12 (evalCluster wrapper), 13 (integrated), 14 (deferredModule), 15 (override layers), 16B (refined), 18 (migration plan)

---

## Design Decisions

1. **Use the NixOS module system.** Don't fight it. `instances` is a well-typed module option, not a custom construct. The module system's merge semantics, priority system, and type checking do the heavy lifting.

2. **Instances are config.** The "sidethought" concern is a visual/convention issue, not an architectural one. A fragment that deploys postgres *is* configuring the cluster to include postgres. The module system treats all config uniformly — that's a feature.

3. **Three override layers** (from doc 15): `config` (module priority), `deps` (collision-detecting merge), `partsOverlays` (list concat). Each instance has these as separately-typed options.

4. **`globalPartsOverlays`**: A new cluster-level option. Overlays in this list are prepended to every instance's `partsOverlays`. This enables cross-cutting structural concerns (monitoring, PDB injection, sidecars) without module-level circularity.

5. **`ref` via `specialArgs`.** The outer fixpoint is passed to all modules as `ref`. Nix laziness ensures no cycles — `ref` thunks resolve during instance evaluation, not during module merge.

6. **Typed package options** via `{ options, build }`. Each package returns an attrset with `options` (NixOS-style option declarations) and `build` (a function receiving `{ self, config, clusterConfig }` that returns parts). The evaluator splits these: it runs `evalModules` with the package's options + instance config, then passes the evaluated config to `build`. No sidecar files.

7. **`scope.defaults` is removed.** Defaults live in package `options` declarations. This is a breaking change — all packages must adopt the `{ options, build }` pattern.

---

## Module Options (`lib/modules.nix`)

```nix
# lib/modules.nix
{ lib }:
{
  options = {

    clusterLabels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Labels injected into every resource.";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.submodule {
        options = {
          package = lib.mkOption {
            type = lib.types.uniq lib.types.anything;
            description = ''
              The package function. types.uniq ensures two modules
              declaring the same (ns, instance) with different packages
              is a merge error.
            '';
          };
          packageType = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "DI resolution key. Defaults to instance name.";
          };
          aliases = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Additional DI resolution keys.";
          };
          config = lib.mkOption {
            type = lib.types.deferredModule;
            default = {};
            description = ''
              Instance configuration. Multiple modules can contribute
              config to the same instance — they merge via deferredModule.
              Use mkDefault/mkForce for priority control.
            '';
          };
          deps = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = {};
            description = ''
              Explicit DI overrides. Keys are package function arg names.
              Collision = error (two modules setting same dep for same
              instance must be resolved explicitly).
            '';
          };
          partsOverlays = lib.mkOption {
            type = lib.types.listOf lib.types.anything;
            default = [];
            description = ''
              Parts overlay functions (self: base: { ... }). Applied in
              order after package evaluation. Multiple modules contribute
              overlays — they concatenate.
            '';
          };
          version = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
        };
      }));
      default = {};
    };

    namespaces = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          labels = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
          };
          annotations = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
          };
          resourceQuota = lib.mkOption {
            type = lib.types.nullOr lib.types.anything;
            default = null;
          };
          networkPolicies = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = {};
          };
        };
      });
      default = {};
    };

    # Global parts overlays — applied to every instance.
    globalPartsOverlays = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [];
      description = ''
        Parts overlay functions applied to ALL instances. These run
        inside each instance's fixpoint — the overlay sees (self, base)
        where base is the package's evaluated parts. Use this for
        cross-cutting structural concerns: monitoring, PDB injection,
        sidecars.

        The overlay decides per-instance whether to act by inspecting
        base (e.g., checking if base.service.out ? metricsPort).
        Selection logic lives in the overlay, not the module system.
      '';
    };

    # Global config — available to packages via scope.clusterConfig.
    # Also injected as lowest-priority defaults into per-instance
    # deferredModule evaluation.
    global = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = ''
        Cluster-wide configuration values. Packages read these via
        scope.clusterConfig.global or through _kixOptions defaults
        that reference them. Not for wiring — use DI for that.
      '';
    };
  };
}
```

### Key type choices

| Field | Type | Merge behavior |
|-------|------|---------------|
| `package` | `types.uniq types.anything` | Two modules → error |
| `config` | `types.deferredModule` | Deep merge with priority (`mkDefault`/`mkForce`) |
| `deps` | `types.attrsOf types.anything` | Attrset merge; collision on same key → error |
| `partsOverlays` | `types.listOf types.anything` | List concatenation (ordered) |
| `aliases` | `types.listOf types.str` | List concatenation |

`package` uses `types.uniq` because an instance's identity is defined by its package. If two fragments both want to deploy something at the same (namespace, instance), they're either the same package (and should merge config) or different packages (and that's a collision).

`config` uses `types.deferredModule` because multiple fragments legitimately contribute config to the same instance. A team sets `replicaCount = 5`, a policy fragment sets `monitoring.enabled = mkDefault true` — both merge cleanly.

---

## buildCluster — New Signature

```nix
# lib/eval.nix (new buildCluster)
buildCluster = { name ? "cluster", modules }:
  let
    # 1. Evaluate modules
    evaluated = lib.evalModules {
      modules = [ (import ./modules.nix { inherit lib; }) ] ++ modules;
      specialArgs = {
        ref = clusterInstances;  # lazy — resolved during fixpoint
      };
    };

    cfg = evaluated.config;

    # 2. Derive namespace list from instances keys ∪ explicit namespaces
    allNsNames = lib.unique (
      builtins.attrNames cfg.namespaces
      ++ builtins.attrNames cfg.instances
    );

    # 3. Create namespace resources
    nsResources = builtins.listToAttrs (map (nsName: {
      name = nsName;
      value = mkNamespace ({ name = nsName; } // (cfg.namespaces.${nsName} or {}));
    }) allNsNames);

    # 4. Build static metadata for DI resolution (reads only packageType/aliases)
    staticMeta = lib.mapAttrs (nsName: nsInsts:
      lib.mapAttrs (instName: instCfg: {
        _meta = {
          instanceName = instName;
          namespaceName = nsName;
          namespace = nsName;
          packageType = instCfg.packageType or instName;
          aliases = instCfg.aliases or [];
        };
      }) nsInsts
    ) cfg.instances;

    resolutionIndex = buildResolutionIndex staticMeta;

    # 5. Build nested fixpoint
    clusterInstances = lib.fix (self:
      lib.mapAttrs (nsName: nsInsts:
        lib.mapAttrs (instName: instCfg:
          evaluateInstance {
            instanceName = instName;
            namespaceName = nsName;
            instanceConfig = instCfg // { _namespace = nsName; };
            namespaceResource = nsResources.${nsName};
            allInstances = self;
            clusterLabels = cfg.clusterLabels;
            inherit resolutionIndex;
            globalPartsOverlays = cfg.globalPartsOverlays;
            clusterConfig = cfg;
          };
        ) nsInsts
      ) cfg.instances
    );

    # ... rest unchanged (activation, registry, rawManifests) ...
  in { ... };
```

### The `ref` + `evalModules` mutual recursion

This works because of Nix laziness:

1. `evalModules` produces the config tree lazily
2. `config.instances.*.*.config` is `deferredModule` — stored as-is, never forced during merge
3. Values like `"${ref.nginx-system.ingress.out.fqdn}"` are unevaluated thunks in the config tree
4. `buildResolutionIndex` reads only `packageType`/`aliases` — never touches `config` values
5. Thunks are forced during `evaluateInstance` inside the fixpoint, where `ref = self` is available

This is the same laziness pattern NixOS uses for modules referencing each other's config.

---

## evaluateInstance — Updated

Three changes from current:
1. Package returns `{ options, build }` — evaluator splits them
2. Read explicit DI overrides from `instanceConfig.deps` (not top-level keys)
3. Apply `globalPartsOverlays ++ instanceConfig.partsOverlays`

```nix
evaluateInstance = {
  instanceName, namespaceName, instanceConfig,
  namespaceResource, clusterLabels, resolutionIndex,
  allInstances,
  globalPartsOverlays ? [],
  clusterConfig ? {},
}:
  let
    scope = mkScope {
      inherit instanceName namespaceName namespaceResource clusterLabels;
      inherit clusterConfig;  # available as scope.clusterConfig
    };

    # 1. Call the package function with DI deps — returns { options, build }
    raw = kixCallPackage {
      packageFn = instanceConfig.package;
      inherit scope resolutionIndex allInstances;
      deps = instanceConfig.deps or {};
    };

    # 2. Evaluate typed config: package options + instance config
    evaluatedConfig = evaluateInstanceConfig {
      packageOptions = raw.options;
      inherit instanceConfig clusterConfig;
    };

    # 3. Combine global + instance overlays
    allOverlays = globalPartsOverlays ++ (instanceConfig.partsOverlays or []);

    # 4. Build inner fixpoint — build receives { self, config, clusterConfig }
    parts =
      if allOverlays != [] then
        lib.fix (self:
          let base = raw.build { inherit self clusterConfig; config = evaluatedConfig; };
          in builtins.foldl'
            (acc: overlay: acc // (overlay self acc))
            base
            allOverlays
        )
      else
        lib.fix (self:
          raw.build { inherit self clusterConfig; config = evaluatedConfig; }
        );

    # ... rest unchanged (closure, inverse deps, PackageInstance) ...
  in ...;
```

### kixCallPackage — deps lookup change

```nix
# Before:
explicitOverride = instanceConfig.${argName} or null;

# After:
explicitOverride = (deps).${argName} or null;
```

`kixCallPackage` now returns the `{ options, build }` attrset from the package function, with DI deps resolved and injected into the function args.

---

## Typed Package Options — `{ options, build }`

Every package returns `{ options, build }`. The evaluator splits the two concerns:

```nix
# packages/valkey/default.nix
{ lib, scope, ... }: {
  options = {
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 3;
    };
    sentinel.enabled = lib.mkEnableOption "sentinel mode";
    sentinel.quorum = lib.mkOption {
      type = lib.types.int;
      default = 2;
    };
    monitoring.enabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Emit a ServiceMonitor resource.";
    };
    persistence.enabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    persistence.size = lib.mkOption {
      type = lib.types.str;
      default = "8Gi";
    };
  };

  build = { self, config, clusterConfig }: {
    statefulSet = scope.mkResource {
      kind = "StatefulSet";
      name = "${scope.instanceName}";
      spec.replicas = config.replicaCount;
      # ...
    };
  };
}
```

The outer function receives DI deps (`scope`, other packages). It returns:
- **`options`**: NixOS-style option declarations. The evaluator runs `evalModules` with these + instance config.
- **`build`**: A function receiving `{ self, config, clusterConfig }` that returns the parts attrset. `self` is the fixpoint, `config` is the evaluated instance config, `clusterConfig` is the full cluster-level config.

### Per-instance config evaluation

The evaluator extracts `options` from the package, runs `evalModules` to validate and merge config, then passes the result to `build`:

```nix
evaluateInstanceConfig = { packageOptions, instanceConfig, clusterConfig }:
  (lib.evalModules {
    modules = [
      { options = packageOptions; }                    # package option declarations
      { config = clusterConfig.global or {}; }         # global defaults (lowest priority)
      instanceConfig.config                            # instance config (deferredModule, higher priority)
    ];
  }).config;
```

**Priority stack** (lowest → highest):
1. Package option `default` values (priority 1500)
2. `clusterConfig.global` (priority 1000 — same as `mkDefault`)
3. Instance `config` from fragments (priority 100 — normal)
4. `mkForce` in platform fragments (priority 50)

A package just reads `config.monitoring.enabled` — it doesn't need to know whether the value came from its own default, the global config, or an instance-level override.

---

## globalPartsOverlays — Cross-Cutting Structural Concerns

The key insight: selection logic ("does this instance have metrics?") belongs inside the overlay function, not in the module system. The overlay inspects `base` at fixpoint evaluation time.

### Example: Monitoring

```nix
# lib/overlays.nix or inline in fragment
monitoringOverlay = monitoring: self: base:
  let
    svc = base.service or null;
    hasMetrics = svc != null && (svc.out ? metricsPort);
  in
  lib.optionalAttrs hasMetrics {
    serviceMonitor = monitoring.out.mkMonitor {
      target = svc;
      port = svc.out.metricsPort;
      path = svc.out.metricsPath or "/metrics";
    };
  };
```

The monitoring fragment:

```nix
# fragments/nw1/monitoring.nix
{ packages, ... }: { config, lib, ref, ... }: {

  options.monitoring.enabled = lib.mkEnableOption "cluster-wide monitoring";

  config = lib.mkIf config.monitoring.enabled {
    instances.monitoring-system.kube-prometheus-stack = {
      package = packages.kube-prometheus-stack;
      packageType = "kube-prometheus-stack";
    };

    # Every instance with a metricsPort gets a ServiceMonitor
    globalPartsOverlays = [
      (monitoringOverlay ref.monitoring-system.kube-prometheus-stack)
    ];
  };
}
```

Packages know nothing about monitoring. They just expose `metricsPort` on their service:

```nix
# packages/acme-api/default.nix
{ lib, scope, ... }: {
  options = {
    port = lib.mkOption { type = lib.types.int; default = 8080; };
  };

  build = { self, config, clusterConfig }: {
    service = scope.mkResource {
      kind = "Service";
      name = "${scope.instanceName}-api";
      spec.ports = [{ name = "http"; port = config.port; }];
      outputs = { metricsPort = "9090"; metricsPath = "/metrics"; };
    };
    # No monitoring awareness. The overlay adds serviceMonitor if metrics exist.
    main = self.service;
  };
}
```

### Migration: Prometheus → Datadog

Swap the fragment:

```nix
# fragments/nw1/monitoring-datadog.nix
{ packages, ... }: { config, lib, ref, ... }: {

  options.monitoring.enabled = lib.mkEnableOption "cluster-wide monitoring";

  config = lib.mkIf config.monitoring.enabled {
    instances.monitoring-system.datadog-agent = {
      package = packages.datadog-agent;
      packageType = "monitoring";
    };

    globalPartsOverlays = [
      (monitoringOverlay ref.monitoring-system.datadog-agent)
    ];
  };
}
```

Both `kube-prometheus-stack` and `datadog-agent` expose `out.mkMonitor` with the same interface (duck typing). The overlay function is reusable. Packages don't change.

### Example: PDB injection in production

```nix
# fragments/nw1/policy-prod.nix
{ ... }: { config, lib, ... }: {

  config.globalPartsOverlays = [
    (self: base:
      let
        deploy = base.deployment or null;
        isProd = lib.hasPrefix "prod" (base._meta.namespaceName or "");
        # Only add PDB if there's a deployment and we're in a prod namespace
      in
      lib.optionalAttrs (deploy != null && isProd) {
        pdb = scope.mkResource {
          apiVersion = "policy/v1";
          kind = "PodDisruptionBudget";
          name = "${scope.instanceName}-pdb";
          spec = {
            minAvailable = 1;
            selector.matchLabels = deploy.out.selector;
          };
        };
      })
  ];
}
```

**Note:** The overlay needs `scope` and namespace info. Two options:

1. **Pass metadata via `base`:** The evaluator injects `_meta = { namespaceName, instanceName, ... }` into the base parts. Overlays can read it.
2. **Closure over scope:** The evaluator creates the overlay closure with scope already bound. `globalPartsOverlays` functions receive `(scope: self: base: ...)` and the evaluator partially applies scope.

Option 2 is cleaner:

```nix
# globalPartsOverlays type is actually: list of (scope → self → base → attrset)
# The evaluator does:
#   allOverlays = map (o: o scope) (globalPartsOverlays ++ inst.partsOverlays);

config.globalPartsOverlays = [
  (scope: self: base:
    let
      deploy = base.deployment or null;
      isProd = lib.hasPrefix "prod" scope.namespaceName;
    in
    lib.optionalAttrs (deploy != null && isProd) {
      pdb = scope.mkResource {
        apiVersion = "policy/v1";
        kind = "PodDisruptionBudget";
        name = "${scope.instanceName}-pdb";
        spec.minAvailable = 1;
        spec.selector.matchLabels = deploy.out.selector;
      };
    })
];
```

The evaluator in `evaluateInstance`:

```nix
# Bind scope to overlays
boundOverlays = map (o: o scope) allOverlays;

parts = lib.fix (self:
  builtins.foldl'
    (acc: overlay: acc // (overlay self acc))
    (innerFn self)
    boundOverlays
);
```

---

## What Fragments Look Like

### Platform infrastructure

```nix
# fragments/nw1/infra.nix
{ packages, kix, ... }: { config, lib, ref, ... }: {

  options.tls.issuer = lib.mkOption {
    type = lib.types.str;
    default = "letsencrypt-prod";
  };

  options.dnsRewrites = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        hostname = lib.mkOption { type = lib.types.str; };
        target = lib.mkOption {
          type = lib.types.enum [ "private" "public" ];
          default = "private";
        };
      };
    });
    default = [];
  };

  config.instances = {
    kube-system.coredns = {
      package = packages.coredns;
      packageType = "coredns";
      config = {
        dnsRewrites = config.dnsRewrites;
        servers = [{
          plugins = [
            { name = "rewrite";
              parameters = "name exact registry.nw1.example.net ${ref.nginx-system.ingress-private-v2.out.fqdn} answer auto"; }
          ];
        }];
      };
    };

    cert-manager.cert-manager = {
      package = packages.cert-manager;
      packageType = "cert-manager";
    };

    cert-manager.cluster-issuers = {
      package = packages.cluster-issuers;
      packageType = "cluster-issuer";
      config = { mainIssuer = config.tls.issuer; };
    };

    nginx-system.ingress-public-v2 = {
      package = packages.ingress-nginx;
      packageType = "ingress-nginx";
      aliases = [ "ingress-public" ];
      config = { controllerClass = "public"; };
    };

    nginx-system.ingress-private-v2 = {
      package = packages.ingress-nginx;
      aliases = [ "ingress-private" ];
      config = { controllerClass = "private"; };
    };

    storage.ceph-fast = {
      package = packages.ceph-storage;
      packageType = "storage-class";
      config = { pool = "fast-ssd"; };
    };
  };
}
```

### Application team

```nix
# fragments/nw1/shopfront.nix
{ packages, ... }:
let
  shopfrontExtensions = [ "pgcrypto" "citext" "pg_trgm" ];

  mkShopfrontEnv = envName: envConfig: { config, lib, ref, ... }: {
    config.instances.${envName} = {
      "${envName}-general" = {
        package = packages.python-app;
        packageType = "python-app";
        config = {
          appName = "shopfront";
          environment = envConfig.environment;
          backend.image = {
            repository = "ghcr.io/northwind/shopfront/web";
            tag = envConfig.imageTag;
          };
          backend.replicaCount = envConfig.replicas;
          ingress.enabled = true;
          ingress.hosts = envConfig.hosts;
        };
      };

      postgres = {
        package = packages.stackgres-cluster;
        packageType = "postgres";
        config = {
          instances = envConfig.pgInstances;
          postgres.version = "16";
          postgres.extensions = shopfrontExtensions;
          storage.size = envConfig.pgStorage;
        };
      };

      "valkey-${envName}" = {
        package = packages.valkey;
        packageType = "valkey";
        config = {
          replicaCount = envConfig.valkeyReplicas;
          sentinel.enabled = true;
          metrics.enabled = true;
          persistence = { enabled = true; size = "20Gi"; };
        };
      };
    };

    config.tenants.acme.namespaces = [ envName ];
    config.priorities.${envName} = { value = envConfig.priority; };
    config.dnsRewrites = map (h: {
      hostname = h.host;
      target = "public";
    }) envConfig.hosts;
  };
in
{ config, lib, ... }: {
  imports = [
    (mkShopfrontEnv "shopfront-prod" {
      environment = "production";
      imageTag = "v26.12.4";
      replicas = 16;
      pgInstances = 3;
      pgStorage = "400Gi";
      valkeyReplicas = 3;
      priority = 1000;
      hosts = [
        { host = "admin.packwise.example"; paths = [{ path = "/"; service = "backend"; }]; }
        { host = "packwise.example"; paths = [{ path = "/"; service = "backend"; }]; }
      ];
    })
    (mkShopfrontEnv "shopfront-stage" {
      environment = "staging";
      imageTag = "v26.12.5-rc1";
      replicas = 4;
      pgInstances = 2;
      pgStorage = "100Gi";
      valkeyReplicas = 1;
      priority = 500;
      hosts = [
        { host = "staging.packwise.example"; paths = [{ path = "/"; service = "backend"; }]; }
      ];
    })
  ];
}
```

### Policy: monitoring

```nix
# fragments/nw1/monitoring.nix
{ packages, kix, ... }: { config, lib, ref, ... }: {

  options.monitoring.enabled = lib.mkEnableOption "cluster-wide Prometheus monitoring";

  config = lib.mkIf config.monitoring.enabled {
    instances.monitoring-system = {
      kube-prometheus-stack = {
        package = kix.fromHelmChart { /* ... */ };
        packageType = "kube-prometheus-stack";
      };
      loki    = { package = kix.fromHelmChart { /* ... */ }; };
      promtail = { package = kix.fromHelmChart { /* ... */ }; };
    };

    # Inject ServiceMonitors into all instances with metrics
    globalPartsOverlays = [
      (scope: self: base:
        let
          svc = base.service or null;
          hasMetrics = svc != null && (svc.out ? metricsPort);
          monitoring = ref.monitoring-system.kube-prometheus-stack;
        in
        lib.optionalAttrs hasMetrics {
          serviceMonitor = monitoring.out.mkMonitor {
            target = svc;
            port = svc.out.metricsPort;
            path = svc.out.metricsPath or "/metrics";
          };
        })
    ];
  };
}
```

### Cluster composition

```nix
# clusters/nw1.nix
{ kix, packages }:

kix.buildCluster {
  name = "nw1";
  modules = [
    ({ lib, ... }: {
      config.clusterLabels = {
        "app.kubernetes.io/part-of" = "nw1";
        cluster = "nw1-prod";
        team = "platform";
      };
      config.monitoring.enabled = true;
    })

    (import ../fragments/nw1/infra.nix { inherit packages kix; })
    (import ../fragments/nw1/monitoring.nix { inherit packages kix; })
    (import ../fragments/nw1/operators.nix { inherit packages kix; })

    (import ../fragments/nw1/shopfront.nix { inherit packages; })
    (import ../fragments/nw1/apps.nix { inherit packages; })
  ];
}
```

~20 lines instead of 2200.

---

## Evaluation Pipeline

```
┌──────────────────────────────────────────────────────────┐
│ 1. lib.evalModules                                       │
│    - Merge all fragment options/config                    │
│    - specialArgs: { ref = clusterInstances (lazy) }      │
│    - Output: cfg.instances, cfg.namespaces,              │
│              cfg.clusterLabels, cfg.globalPartsOverlays,  │
│              cfg.global                                   │
├──────────────────────────────────────────────────────────┤
│ 2. Static metadata extraction                            │
│    - Read packageType + aliases from cfg.instances        │
│    - NO config values touched (avoids forcing ref thunks) │
│    - Build resolutionIndex                               │
├──────────────────────────────────────────────────────────┤
│ 3. Namespace creation                                    │
│    - mkNamespace for each ns in instances ∪ namespaces    │
├──────────────────────────────────────────────────────────┤
│ 4. Nested fixpoint (lib.fix)                             │
│    For each instance:                                    │
│    a. kixCallPackage — resolve DI deps, call packageFn   │
│       - Returns { options, build }                       │
│       - Explicit deps: inst.deps.argName                 │
│       - Auto: resolutionIndex → same-ns → cluster-wide   │
│    b. evaluateInstanceConfig — evalModules with:         │
│       - Package options + global defaults + instance cfg │
│    c. Call build with { self, config, clusterConfig }    │
│    d. Apply overlays: globalPartsOverlays ++ partsOverlays│
│       - Each overlay: (scope → self → base → attrset)    │
│       - Overlays inspect base to decide whether to act   │
│    e. Build instance fixpoint (lib.fix)                  │
│    f. Compute closure, inverse deps, PackageInstance     │
├──────────────────────────────────────────────────────────┤
│ 5. Output                                                │
│    - clusterInstances (nested fixpoint)                  │
│    - namespaces                                          │
│    - activation (cluster root)                           │
│    - rawManifests                                        │
└──────────────────────────────────────────────────────────┘
```

---

## Overlay Signature

All overlays (both `globalPartsOverlays` and per-instance `partsOverlays`) have the same signature:

```
scope → self → base → attrset
```

- **`scope`**: The instance's scope object (`instanceName`, `namespaceName`, `mkResource`, etc.)
- **`self`**: The final fixpoint (for self-references)
- **`base`**: The accumulated parts so far (package + earlier overlays)
- **Returns**: Attrset of parts to merge into base. `null` values remove parts.

The evaluator partially applies `scope` before folding:

```nix
boundOverlays = map (o: o scope) allOverlays;
parts = lib.fix (self:
  builtins.foldl'
    (acc: overlay: acc // (overlay self acc))
    (innerFn self)
    boundOverlays
);
```

Per-instance `partsOverlays` use the same signature. Since the instance's package can close over `scope` anyway, per-instance overlays that don't need `scope` can ignore it.

---

## Changes from Current Code

### lib/eval.nix

| Function | Change |
|----------|--------|
| `buildCluster` | New signature `{ name, modules }`. Uses `evalModules` + `specialArgs`. Passes `globalPartsOverlays` and `clusterConfig` to `evaluateInstance`. |
| `evaluateInstance` | Splits package return into `{ options, build }`. Evaluates typed config via `evaluateInstanceConfig`. Calls `build` with `{ self, config, clusterConfig }`. Applies `globalPartsOverlays ++ inst.partsOverlays` (3-arg overlays). |
| `evaluateInstanceConfig` | New. Runs `evalModules` with package `options` + instance config + global defaults. |
| `kixCallPackage` | Returns the `{ options, build }` attrset. Reads dep overrides from `deps` arg instead of top-level keys. |
| `mkScope` | Adds `clusterConfig` to scope object. |

### lib/modules.nix (new)

Core module options: `clusterLabels`, `instances`, `namespaces`, `globalPartsOverlays`, `global`.

### lib/default.nix

Export new `buildCluster`. Remove `mergeFragments`.

### Packages (breaking change)

All packages must return `{ options, build }`. The `build` function receives `{ self, config, clusterConfig }` as a single attrset argument. `scope.defaults` is removed — use `options` with `lib.mkOption` defaults instead.

---

## Conflict Resolution

| Scenario | Behavior |
|----------|----------|
| Two fragments declare same `(ns, inst)` with different `package` | `types.uniq` error: "defined in multiple modules" |
| Two fragments declare same `(ns, inst)` with same `package` | OK — `config` merges via deferredModule, `partsOverlays` concatenate |
| Two fragments set same config key at same priority | Module merge error: "conflict, use mkForce/mkDefault" |
| Policy sets `config.x = mkForce val` | Wins over all non-force settings |
| Two fragments set same `deps.x` | Collision error (deps don't merge — wiring must be unambiguous) |
| Multiple `globalPartsOverlays` entries | Concatenate in module order, each sees accumulated result |
| Overlay returns `{ hpa = null; }` | Removes `hpa` from parts |

---

## What This Design Does NOT Include

- **Abstract interfaces / type classes for DI** — packages declare concrete deps, cluster operator substitutes via `deps`/`aliases`. Duck typing catches errors.
- **Automatic network policies from DI graph** — future extension, not blocking.
- **`mkEnv` rewrite** — `mkEnv` becomes a module generator (returns a module that sets `config.instances`). Same idea as current `mkShopfrontEnv` pattern above. Detailed design deferred.
- **Transformer functions** (`withCert`, `withStorageClass`) — orthogonal to module system. Packages can expose these via `out` today. No module system changes needed.
