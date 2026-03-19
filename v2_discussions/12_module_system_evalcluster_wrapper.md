# Module System Approach A: evalCluster as Module Layer Above buildCluster

## Working Document — March 2026

**Status:** Design exploration
**Predecessors:** doc 01 (evaluateCluster merging), doc 06 (team DX), outdated/modules/

---

## 1. The Problem

kix currently uses `scope.defaults config defs` (a deep `recursiveUpdate`) for
package configuration. There is no mechanism for cross-cutting concerns — if a
platform team wants "monitoring enabled cluster-wide" or a fragment wants to
declare "I provide TLS certificates, here are the options", there's nowhere to
put that. Each fragment/cluster definition is isolated and can only set instance
configs directly.

The roadmap lists:
- proper module system for config
- no "defaults"
- global config object that is passed around
- fragments for separating concerns and teams

---

## 2. Core Idea

Add a new entry point `evalCluster` that wraps `buildCluster`. It runs
`lib.evalModules` once per cluster to merge all modules into a resolved config,
then feeds the result into the existing `buildCluster` machinery unchanged.

Two separate phases, two separate fixpoints:

1. **Module evaluation** (`lib.evalModules`) — merges cross-cutting options,
   namespace policies, instance declarations. All modules can read and set
   options. The module system's internal fixpoint resolves lazy cross-references.

2. **Resource evaluation** (`buildCluster`) — takes the plain config from
   phase 1, runs the existing nested fixpoint (DNS-like DI, package evaluation,
   inner parts fixpoint, closure computation). Unchanged.

---

## 3. API

```nix
# New entry point
kix.evalCluster {
  name = "nw1";
  clusterLabels = { "kix.dev/cluster" = "nw1"; };
  modules = [
    ./fragments/platform.nix
    ./fragments/team-shopfront.nix
    ({ ... }: { config.monitoring.enabled = true; })
  ];
}
```

Each fragment is a NixOS-style module:

```nix
# fragments/platform.nix
{ lib, config, ... }: {
  # Declare a cross-cutting option
  options.monitoring = {
    enabled = lib.mkEnableOption "cluster-wide monitoring";
    provider = lib.mkOption {
      type = lib.types.enum [ "prometheus" "victoria-metrics" ];
      default = "prometheus";
    };
  };

  # Provide infrastructure instances
  config.instances.monitoring.prometheus = {
    package = packages.prometheus;
    packageType = "prometheus";
  };
}
```

```nix
# fragments/team-shopfront.nix
{ config, lib, ... }: {
  config.monitoring.enabled = true;  # sets platform's option

  config.instances.shopfront-prod.shopfront = {
    package = packages.python-app;
    packageType = "python-app";
    config.backend.image.tag = "v2.3.1";
  };
}
```

---

## 4. Built-in Module Options

Provided by kix core modules (always loaded):

```
cluster.domain          : str          (default "cluster.local")
cluster.labels          : attrsOf str  (default {})
namespaces.<ns>.labels  : attrsOf str
namespaces.<ns>.annotations : attrsOf str
namespaces.<ns>.resourceQuota : nullOr attrs
namespaces.<ns>.networkPolicies : attrsOf attrs
instances.<ns>.<inst>.package : anything
instances.<ns>.<inst>.packageType : str
instances.<ns>.<inst>.config : deferredModule     # configuration (behavior)
instances.<ns>.<inst>.deps : attrsOf anything      # DI overrides (wiring, like .override)
instances.<ns>.<inst>.partsOverlays : listOf fn    # resource overlays (like .overrideAttrs)
instances.<ns>.<inst>.aliases : listOf str
instances.<ns>.<inst>.version : nullOr str
```

User modules can declare any additional options (monitoring, networking, TLS,
RBAC policies, etc.).

---

## 5. Instance Collision Detection

Uses a custom merge type on `instances.<ns>.<inst>` that errors when two modules
define the same (namespace, instance) pair — same semantics as current
`mergeFragments`:

```nix
type = lib.types.mkOptionType {
  name = "instance";
  merge = loc: defs:
    if builtins.length defs == 1 then (builtins.head defs).value
    else throw "instance collision at ${lib.showOption loc}: defined by ${
      lib.concatMapStringsSep ", " (d: d.file) defs
    }";
};
```

---

## 6. scope.clusterConfig

The evaluated module config is passed to packages via `scope.clusterConfig` so
packages can read global settings:

```nix
# In a package — reads cross-cutting option
{ scope, config, lib }: self: {
  serviceMonitor =
    if scope.clusterConfig.monitoring.enabled or false
    then scope.mkResource { kind = "ServiceMonitor"; ... }
    else null;
}
```

---

## 7. What Stays the Same

- Package functions: `{ scope, config, lib, ...deps }: self: { ... }`
- DNS-like dependency resolution
- Inner fixpoint (parts), outer fixpoint (instances)
- String context dependency tracking
- `mkResource`, `mkClusterResource`, `rbac`

Note: `scope.defaults` is superseded by the module system's option declarations
and merging. Packages receive fully-merged config from the module system —
defaults are declared via `mkOption { default = ...; }` in package options,
not via `scope.defaults`.

---

## 8. What Changes

- `buildCluster` unchanged, `evalCluster` is the new recommended entry point
- Fragments become NixOS-style modules instead of `mergeFragments` input
- `mergeFragments` eventually removed
- Instance declarations are plain attrsets (no `{ ref, ... }:` function)
- Cross-instance wiring stays in package function args via DI, not in config

---

## 9. Key Tradeoff

Module config cannot reference evaluated instance outputs (resources,
`out.name`, etc.) because modules run before `buildCluster`. Config is *input*,
resources are *output*. This is intentional — resource wiring uses the DI
system, not the module system.

---

## 10. Relationship to buildCluster

This approach keeps `buildCluster` as the low-level API and layers modules on
top. Backward compatible — existing cluster definitions that call `buildCluster`
directly continue to work. Migration is gradual.

If the decision is to replace `buildCluster` directly (see doc 13), this
approach becomes the internal implementation rather than a separate function.
