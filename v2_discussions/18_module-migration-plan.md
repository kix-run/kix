# Plan: Migrate to Module System

## Context

kix clusters are currently monolithic files (nw1.nix = 2204 lines). The module system design (docs 12-17) has been refined and approved. This plan implements it in two phases: library changes, then cluster migration. The old `buildCluster` API (taking an `instances` function) is replaced entirely — no backwards compat.

The goal is to split cluster definitions by persona/team concern using NixOS-style modules, while keeping DI resolution unchanged.

---

## Phase 1: Library — New Module-Based buildCluster

### 1.1 Create `lib/modules.nix` — Built-in Module Options

New file. Declares the core options that every cluster module tree shares:

```nix
# lib/modules.nix
{ lib }:
{
  options = {
    clusterLabels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Labels injected into every resource in the cluster.";
    };

    instances = lib.mkOption {
      # instances.<namespace>.<instanceName> = { package, packageType?, config?, deps?, aliases?, parts?, version? }
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.submodule {
        options = {
          package = lib.mkOption { type = lib.types.anything; };
          packageType = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          aliases = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
          # lib.types.anything — NOT deeply typed. Values may contain lazy
          # ref thunks that must not be forced during module evaluation.
          config = lib.mkOption { type = lib.types.anything; default = {}; };
          deps = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
          parts = lib.mkOption { type = lib.types.nullOr lib.types.anything; default = null; };
          version = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
        };
      }));
      default = {};
    };

    namespaces = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          labels = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; };
          # future: annotations, quota, networkPolicies
        };
      });
      default = {};
    };
  };
}
```

**File:** `lib/modules.nix` (new)

### 1.2 Rewrite `buildCluster` in `lib/eval.nix`

Replace the current `buildCluster` signature:

```nix
# OLD
buildCluster = { name, namespaces?, instances, clusterLabels? }: ...

# NEW
buildCluster = { name, modules }: ...
```

`clusterLabels` moves into module config (`config.clusterLabels`).

New flow:
1. Run `lib.evalModules` with `specialArgs = { ref = clusterInstances; }` — this makes `ref` available to all modules as a function arg, just like nixpkgs passes `pkgs`
2. Extract `config.instances`, `config.namespaces`, `config.clusterLabels` from the evaluated module tree
3. Auto-derive namespace list from instances keys ∪ explicit namespaces (same as today)
4. Build staticMeta from `config.instances` — only reads `packageType`/`aliases`, never touches `config` values, so no cycle with the fixpoint
5. Build resolutionIndex (same as today)
6. Build the nested fixpoint — `clusterInstances = lib.fix (self: ...)` — instances come from module config, `ref` points at `self`

**The `ref` + `evalModules` mutual recursion works because of Nix laziness:**
- `evalModules` produces the config tree lazily
- `config.instances.*.*.config` is `lib.types.anything` — the module system stores values as-is without forcing them
- Values like `"... ${ref.nginx-system.ingress-private-v2.out.fqdn} ..."` are unevaluated thunks in the config tree
- `buildResolutionIndex` only reads `packageType`/`aliases` (never `config`) — no cycle
- The thunks are only forced during `evaluateInstance` inside the fixpoint — where `ref = self` is available
- This is the same pattern NixOS uses for modules referencing each other's config

Modules use `ref` naturally:
```nix
{ config, lib, ref, ... }: {
  config.instances.kube-system.coredns.config.servers = [{
    plugins = [{
      name = "rewrite";
      parameters = "name exact registry.nw1.example.net ${ref.nginx-system.ingress-private-v2.out.fqdn} answer auto";
    }];
  }];
}
```

Key change in `kixCallPackage`: currently explicit overrides come from top-level keys on instanceConfig (e.g. `instanceConfig.postgres = ref.ns.pg`). With modules, they come from `instanceConfig.deps.postgres`. Update the override lookup to check `instanceConfig.deps.${argName}` instead of `instanceConfig.${argName}`.

**Files:** `lib/eval.nix` (modify buildCluster + kixCallPackage deps handling)

### 1.3 Update `lib/default.nix`

Export the new buildCluster. Remove or keep `mergeFragments` (the module system supersedes it, but it's harmless to keep for now).

**File:** `lib/default.nix` (minor update)

### 1.4 Update test clusters

Rewrite `test-minimal.nix`, `example.nix`, `test-full.nix` to use the new `modules` API. These are small files and serve as smoke tests for the new API.

```nix
# test-minimal.nix — new shape
{ kix, packages }:
kix.buildCluster {
  name = "test-minimal";
  modules = [
    ({ lib, ... }: {
      config.instances.kube-system.coredns = {
        package = packages.coredns;
        packageType = "coredns";
      };
    })
  ];
}
```

Note: `ref` is available as a module arg (`{ config, lib, ref, ... }:`) but test-minimal doesn't need it.

**Files:** `clusters/test-minimal.nix`, `clusters/example.nix`, `clusters/test-full.nix`, `clusters/test-helm.nix`

### 1.5 Verification

```bash
# Build all test clusters — must produce identical manifests to before
nix build .#cluster-minimal --extra-experimental-features pipe-operators
nix build .#cluster-example --extra-experimental-features pipe-operators
nix build .#cluster-full --extra-experimental-features pipe-operators

# Run checks
nix flake check --extra-experimental-features pipe-operators
```

Compare `./result` output before and after for test clusters to verify no manifest drift.

---

## Phase 2: Cluster Migration — Split nw1.nix into Fragments

### 2.1 Create fragment directory

```
fragments/
  nw1/
    infra.nix        — core platform infra
    monitoring.nix   — monitoring stack
    operators.nix    — system operators and tools
    shopfront.nix      — shopfront team (all envs)
    apps.nix         — ledgerly, n8n, metabase
```

### 2.2 Fragment: `fragments/nw1/infra.nix` (Platform Infra)

**Persona:** Platform Engineer / Cluster Operator

Contains:
- **kube-system:** coredns, external-dns-cluster-public, external-dns-northwind, reloader, priority-classes, storage-classes, network-policies, cert-manager
- **nginx-system:** ingress-public-v2, ingress-private-v2
- **cert-manager:** cluster-issuers

Also contains shared helpers that are platform-level: `mkSgBackup`.

The DNS rewrite `ref` usage in coredns (lines 226-238 of current nw1.nix) uses `ref` naturally since it's available as a module arg:

```nix
# fragments/nw1/infra.nix
{ packages, kix, ... }:
{ config, lib, ref, ... }: {
  config.instances.kube-system.coredns.config.servers = [{
    plugins = [
      # ...
      { name = "rewrite";
        parameters = "name exact registry.nw1.example.net ${ref.nginx-system.ingress-private-v2.out.fqdn} answer auto"; }
      # ...
    ];
  }];
}
```

### 2.3 Fragment: `fragments/nw1/monitoring.nix` (Monitoring Stack)

**Persona:** Platform Engineer / SRE

Contains:
- **monitoring-system:** kube-prometheus-stack (Helm), loki (Helm), promtail (Helm)

### 2.4 Fragment: `fragments/nw1/operators.nix` (System Operators)

**Persona:** Platform Engineer

Contains:
- **stackgres-system:** stackgres-operator
- **harbor-system:** harbor, harbor-postgres
- **velero-system:** velero
- **tailscale-system:** tailscale
- **kubevirt:** kubevirt
- **cdi:** cdi
- **arc-system:** arc
- **infisical-operator-system:** infisical-operator

### 2.5 Fragment: `fragments/nw1/shopfront.nix` (Shopfront Team)

**Persona:** Application Developer (Shopfront)

Contains:
- The `mkShopfrontEnv` helper (moved from nw1.nix let-block)
- `shopfrontExtensions`, `valkeyRenameCommands` (shared config)
- **shopfront-prod**, **shopfront-stage**, **shopfront-demo** — all three envs via mkShopfrontEnv

### 2.6 Fragment: `fragments/nw1/apps.nix` (Other Applications)

**Persona:** Application Developers (Ledgerly, internal tools)

Contains:
- **ledgerly-prod:** ledgerly (python-app), postgres, valkey
- **n8n:** n8n, postgres, valkey
- **metabase:** metabase, postgres

### 2.7 Rewrite `clusters/nw1.nix` as Composition

```nix
# clusters/nw1.nix — NW1 production cluster (Northwind @ Hetzner)
{ kix, packages }:

kix.buildCluster {
  name = "nw1";
  modules = [
    # Cluster-wide config
    ({ lib, ... }: {
      config.clusterLabels = {
        "app.kubernetes.io/part-of" = "nw1";
        "cluster" = "nw1-prod";
        "team" = "platform";
      };
    })

    # Platform infra (Luca owns)
    (import ../fragments/nw1/infra.nix { inherit packages kix; })
    (import ../fragments/nw1/monitoring.nix { inherit packages kix; })
    (import ../fragments/nw1/operators.nix { inherit packages kix; })

    # Application teams
    (import ../fragments/nw1/shopfront.nix { inherit packages; })
    (import ../fragments/nw1/apps.nix { inherit packages; })
  ];
}
```

~25 lines instead of 2204.

### 2.8 Verification

```bash
# Build nw1 — must produce identical manifests
nix build .#cluster-nw1 --extra-experimental-features pipe-operators

# Diff against live cluster
./scripts/kix-dump.py --all cluster-dump/
./scripts/kix-diff.py ./result cluster-dump/

# Full check suite
nix flake check --extra-experimental-features pipe-operators
```

**Critical:** Save the pre-migration `./result` output (or its hash) BEFORE starting, then compare after. The module system migration must produce bit-for-bit identical manifests — it's a refactor, not a behavior change.

---

## Key Files

| File | Action | Phase |
|------|--------|-------|
| `lib/modules.nix` | Create | 1.1 |
| `lib/eval.nix` | Rewrite buildCluster, update kixCallPackage | 1.2 |
| `lib/default.nix` | Minor export update | 1.3 |
| `clusters/test-minimal.nix` | Rewrite to modules API | 1.4 |
| `clusters/example.nix` | Rewrite to modules API | 1.4 |
| `clusters/test-full.nix` | Rewrite to modules API | 1.4 |
| `clusters/test-helm.nix` | Rewrite to modules API | 1.4 |
| `fragments/nw1/infra.nix` | Create | 2.2 |
| `fragments/nw1/monitoring.nix` | Create | 2.3 |
| `fragments/nw1/operators.nix` | Create | 2.4 |
| `fragments/nw1/shopfront.nix` | Create | 2.5 |
| `fragments/nw1/apps.nix` | Create | 2.6 |
| `clusters/nw1.nix` | Rewrite as composition | 2.7 |

## Existing Code to Reuse

- `buildResolutionIndex` (`lib/eval.nix:145`) — unchanged, takes staticMeta
- `resolveArg` (`lib/eval.nix:167`) — unchanged
- `kixCallPackage` (`lib/eval.nix:246`) — minor change: read explicit overrides from `inst.deps` instead of top-level inst keys
- `evaluateInstance` (`lib/eval.nix:297`) — unchanged
- `mkScope`, `mkNamespace`, all k8s.nix — unchanged
- `mkShopfrontEnv` (nw1.nix:55-109) — moved to `fragments/nw1/shopfront.nix`, adapted to set `config.instances` instead of returning bare attrset

## NOT in scope

- `packageDefaults` — deferred per discussion, later addition
- DI changes to packages (adding `cluster-issuer ? null` etc.) — separate effort
- `_kixOptions.nix` typed package config — separate effort
- Transformer functions (`withCert` etc.) — separate effort

