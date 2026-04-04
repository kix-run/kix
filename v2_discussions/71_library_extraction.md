# 71: Extracting kix into a Standalone Library

**Status:** Draft
**Related:** `29_compiler-design.md`, `45_multi_team_and_operator_models.md`

---

## Problem

kixpkgs today is a monorepo where the **framework** (lib/, pipeline/, checks), the **package catalog** (packages/), and **example clusters** (clusters/) all live together. This mirrors early nixpkgs — everything in one repo, one flake, one build.

This creates three problems:

1. **Users can't consume kix without forking kixpkgs.** A team that wants to define their own cluster must either fork the whole repo or use flake inputs pointing deep into our tree. There's no clean `kix.lib` they can pull in the way you'd pull in nixpkgs.

2. **The package catalog and the framework evolve at different speeds.** Upgrading a cert-manager package shouldn't require upgrading the compiler, and vice versa. Today they're pinned together.

3. **The flake.nix is infrastructure, not user config.** Users have to understand flake inputs, `perSystem`, `legacyPackages`, `exportReferencesGraph`, and the pipeline derivation builders just to define a cluster. This is accidental complexity — none of it is *their* problem.

devenv.sh solved the same UX problem for Nix dev environments: users write `devenv.nix`, and the flake machinery is generated/managed automatically. kix should do the same.

---

## Design: Three-Layer Split

### Layer 1: `kix` (the framework)

A standalone flake/repo containing:

```
kix/
  lib/           # k8s.nix, eval.nix, compose.nix, rbac.nix, etc.
  checks/        # checks.nix, pi-checks.nix
  cli/           # the Rust CLI
  flake.nix      # exports kix.lib, kix.checks, kix.cli
```

**What it provides:**
- `kix.lib.forPkgs { inherit pkgs lib; }` → `{ buildCluster, mkResource, mkScope, mkManifests, ... }`
- `kix.checks` → schema and wiring validators
- Flavors (k3s, eks, gke, etc.)

**What it does NOT contain:** any packages or clusters. It's the compiler, not the programs.

This is analogous to nixpkgs `lib` — pure functions, no derivations of their own (except the CLI).

### Layer 2: `kixpkgs` (the package catalog)

Stays as a repo, but slimmed down:

```
kixpkgs/
  packages/      # coredns, cert-manager, ingress-nginx, ...
  flake.nix      # inputs: { kix, nixpkgs }; exports packages attrset
```

It imports `kix` and re-exports the package catalog. Users can pin kixpkgs to get a curated, tested set of packages — or ignore it entirely and write inline packages.

Analogous to nixpkgs packages — a catalog you opt into.

### Layer 3: User repo (the cluster)

This is where the new UX matters. The user's repo contains:

```
my-infra/
  kix.nix              # or clusters.kix — the user-facing config
  clusters/
    prod/platform.nix
    prod/services.nix
    staging/...
  packages/             # optional: team-specific packages
```

No `flake.nix` in the user's repo. The `kix` CLI generates/manages it, like devenv does.

---

## User-Facing Config File: `kix.nix` vs `clusters.kix`

### Option A: `kix.nix`

```nix
# kix.nix
{
  # Pinned inputs — kix CLI manages the lock
  inputs.kixpkgs.url = "github:kixpkgs/kixpkgs";

  # Optional: extra package sources
  inputs.team-packages.url = "git+ssh://git@github.com/acme/k8s-packages";

  clusters = {
    prod = {
      modules = [
        ./clusters/prod/platform.nix
        ./clusters/prod/services.nix
      ];
    };

    staging = {
      modules = [
        ./clusters/staging/platform.nix
      ];
    };
  };
}
```

### Option B: `clusters.kix`

```nix
# clusters.kix — evaluated by the kix CLI, not a Nix expression directly
{
  inputs.kixpkgs = "github:kixpkgs/kixpkgs";

  clusters.prod.modules = [
    ./clusters/prod/platform.nix
    ./clusters/prod/services.nix
  ];

  clusters.staging.modules = [
    ./clusters/staging/platform.nix
  ];
}
```

### Comparison

| | `kix.nix` | `clusters.kix` |
|---|---|---|
| **Familiarity** | Nix users recognize it instantly; mirrors devenv.nix, flake.nix | New convention; signals "this isn't just Nix" |
| **Tooling** | Nix syntax highlighting, LSP, linters work out of the box | Needs editor config; or if it's still Nix under the hood, the `.kix` extension misleads |
| **Extensibility** | Full Nix — users can compute cluster lists, conditionals, imports | Same if it's Nix; limited if it's a custom format |
| **Brand identity** | Looks like "just another Nix project" | Clearly branded; kix owns the file |
| **Discoverability** | `kix init` creates `kix.nix` — obvious what it is | `kix init` creates `clusters.kix` — requires explanation |
| **Future optionality** | Tied to Nix syntax forever | Could evolve to a non-Nix format later (TOML, custom DSL) |

**Recommendation:** Start with `kix.nix`. The practical benefits (tooling, familiarity, extensibility) outweigh the branding upside of a custom extension. If kix ever moves away from Nix as the user-facing language, the config file format would change regardless. Don't pay the tooling tax early for a hypothetical future.

---

## How the CLI Bridges the Gap

The `kix` CLI replaces the flake for end users:

```
kix init                    # creates kix.nix + .gitignore for generated files
kix build prod              # generates flake.nix, runs nix build
kix diff prod               # build + diff against live cluster
kix deploy prod             # build + deploy
kix update                  # update kix.lock (input pins)
```

Under the hood, `kix build prod` does:

1. Read `kix.nix`
2. Generate/update a hidden `.kix/flake.nix` (or `flake.nix` with a "DO NOT EDIT" header)
3. Run `nix build .#cluster-prod`

The generated flake wires together: kix framework, kixpkgs catalog, any extra inputs, and the user's cluster modules. Users never touch it. Power users can eject (`kix eject`) to get a plain flake they manage themselves.

---

## Detangling Steps

### Step 1: Draw the boundary in the current repo

Move `lib/`, `pipeline/`, `checks.nix`, `pi-checks.nix`, `cli/` into a `framework/` directory (or just clearly delineate what's "kix" vs "catalog"). No repo split yet — just make the boundary explicit.

### Step 2: Make `forPkgs` the only entry point

Today `flake.nix` uses both the internal `kix = import ./lib ...` and the external `flake.lib.forPkgs`. Converge on one API. Everything a cluster needs should come through `forPkgs` (or a renamed `kix.lib.init`).

### Step 3: Decouple packages from the flake

Packages are already plain functions (`packages/<name>/default.nix`). They don't import from `lib/` at eval time — they receive `scope`, `kix`, etc. as arguments. This means the catalog is already decoupled at the code level; it just needs to be a separate flake input.

### Step 4: Implement `kix.nix` → flake generation in the CLI

The CLI already knows how to evaluate clusters (`legacyPackages.kixClusters`). Add a codepath that reads `kix.nix`, generates the flake, and calls Nix. This is the devenv-style UX.

### Step 5: Split repos

Once the boundary is clean, split into `kix` (framework) and `kixpkgs` (catalog). The current repo becomes kixpkgs, with kix as an input.

---

## What Changes for Package Authors

Nothing. Packages are plain Nix functions that receive `scope`, `kix`, `config`, and DI args. They don't know whether they live in kixpkgs or a private repo. The package API is the stable contract.

## What Changes for Cluster Authors

Before (today):
```nix
# Must understand flake.nix, import paths, perSystem
{ kix, packages }:
kix.buildCluster { ... }
```

After:
```nix
# kix.nix — that's it
{
  inputs.kixpkgs.url = "github:kixpkgs/kixpkgs";
  clusters.prod.modules = [ ./clusters/prod/platform.nix ];
}
```

Cluster modules (`platform.nix`, `services.nix`) stay identical — they already use the module system API, not flake internals.

---

## Open Questions

1. **Flake generation vs flake wrapping?** devenv generates a flake. An alternative is a flake template that `kix init` copies, and the CLI just manages inputs. Generation is more magical but hides more complexity.

2. **Where does the pipeline live?** `annotate.py` and `graph.py` need `pkgs.runCommand` and `exportReferencesGraph`. They're tightly coupled to Nix's build sandbox. They belong in the framework, not the catalog — but they also need `pkgs`. This means the framework flake either takes nixpkgs as an input or the pipeline builders live in `forPkgs`.

3. **Private packages alongside kixpkgs packages?** Users will want both catalog packages and their own. The `kix.nix` should support multiple package sources that merge into a single `availablePackages`. Naming collisions need a resolution strategy (user wins? error?).

4. **Lock file format.** `kix.lock` could be a plain `flake.lock` (reuse Nix's lockfile) or a separate format. Reusing `flake.lock` is simpler but ties us to Nix's input resolution.

5. **Eject story.** When users outgrow the managed flake, `kix eject` should produce a standalone flake.nix they can maintain. What guarantees do we make about the ejected flake staying compatible with future kix versions?
