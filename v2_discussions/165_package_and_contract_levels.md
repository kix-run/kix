# 165: Stability levels for packages and contracts

**Status:** Accepted (direction agreed 2026-11-11). Implemented on branch `package-levels` for 0.10.0, except the items under "Not built". Archive when 0.10.0 ships.
**Related:** `archive/164_versioning_at_agent_speed.md` (the version rules this amends), `archive/164a_versioning_review_record.md`, `166_contracts_as_first_class.md` (where contracts live and what shape they have), `140_catalogue_versions_and_upgrade_windows.md`

## Context

Kix, the Kix library, and the packages share one version. Doc 164 decided that
any breaking change raises the minor and that a patch release never breaks
anything.

New packages change often. Under the current rule, each of those changes
raises the minor for every user, including users who do not use the package.
A project names its Kix minor in `kix.toml`, and Kix builds only a library of
the same minor, so each minor is a step every project has to take.

Kubernetes has the same problem and marks new APIs as alpha. This doc gives
Kix packages and contracts a similar mark.

## Decision

### One sentence of doc 164 changes

- **Before:** a patch release never breaks anything.
- **After:** a patch release never breaks anything stable. An experimental
  package or contract may break in any release.

Everything else in doc 164 stands: one version, one repository, a minor
release for any break to something stable, no deprecation period, and the
rule for reading cluster state.

### The rules

1. **There are two levels, stable and experimental.** A package has one, and
   a contract has one. The two are set separately.
2. **A stable package reads only stable contracts.** An experimental package
   may read stable and experimental contracts.
3. **An experimental package may publish a stable contract.** A stable reader
   can then take it as a dependency. The publisher's own options may still
   break in a patch release, and the fields the contract names may not.
4. **The level shows in the name a user types** (see the next section).
5. **Graduation is a folder move, in any release.** After it, the
   experimental name fails with an error that names the stable one. There is
   no forwarding name. Users of the experimental name change one word.
6. **A stable package can be reworked beside itself.** The rework is an
   experimental package of the same name. It replaces the stable one at a
   minor release.
7. **The library has no experimental level.** A break to a library function
   needs a minor release. Add a level later if a real case appears.
8. **Any kind of break is allowed in an experimental package**, including one
   that shows no error. It still gets a change record.

### Layout and names

```
kix/packages/
  stable/
    immich/
    valkey/
  experimental/
    immich/        a rework, beside the stable one
    plausible/
```

Contracts follow the same layout under `kix/contracts/` (doc 166).

A cluster definition keeps one `packages` input:

```nix
{ packages, ref, ... }:
{
  config.instances = {
    photos.immich.package = packages.immich;
    analytics.plausible.package = packages.experimental.plausible;
  };
}
```

- `packages.immich` is the stable package, as today.
- `packages.stable.immich` is the same package. `packages.stable` exists so
  that code can walk a set that holds only packages. Docs and examples use
  the short form.
- `packages.experimental.plausible` is the experimental package.
- No package can be named `stable` or `experimental`.

The folder layout and these names are joined by about fifteen lines of Nix:

```nix
catalogPackages =
  let
    importAll =
      dir:
      lib.mapAttrs (name: _: import (dir + "/${name}")) (
        lib.filterAttrs (_: type: type == "directory") (builtins.readDir dir)
      );
    stable = importAll ../packages/stable;
    experimental = importAll ../packages/experimental;
    graduated = lib.mapAttrs (
      name: _: throw "`${name}` is stable now. Write `packages.${name}`."
    ) (removeAttrs stable (builtins.attrNames experimental));
  in
  stable // { inherit stable; experimental = graduated // experimental; };
```

The second name costs nothing measurable. Each package is still imported
once, and only when something uses it.

### Why the word is "experimental"

- "alpha" promises a beta, and Kix has one level.
- "unstable" can read as "crashes".
- "preview" is the word Kix uses for seeing a deploy before it happens.
- "contrib" answers who maintains a package. Keep it free for packages that
  outside people maintain.

## What the 0.9.0 breaks show

The level helps most with packages that read contracts, and those are most
new packages.

| Break in 0.9.0 | Side | Packages that would need to be experimental |
|---|---|---|
| `valkey` changed the fields it publishes | Publisher | `valkey`, `harbor`, `immich`, `n8n` |
| ClickHouse changed the fields it publishes | Publisher | The ClickHouse packages and their readers |
| `grafana`, `harbor`, `immich` changed their single sign-on options | Reader | Those three |
| `plausible` took its mail server a new way | Reader | `plausible` |
| `immich` refused a mail password setting | Reader | `immich` |
| `harbor` read the database role from a new place | Reader | `harbor` |
| Option renames and removals in four packages | Neither | Each package alone |

A change on the reader side affects no other package. A change to what a
publisher offers affects every reader. Rule 3 exists for that case: settle
the contract and mark it stable, and the publisher behind it can stay
experimental.

## Experiments (2026-11-11)

Run in a scratch copy of `main` at `db313e74` and compared with builds of
untouched `main`. "Identical" means the built manifests have the same store
path, so every byte and every `kix.run/identity-hash` is the same.

| Test | Result |
|---|---|
| Move all packages into `kix/packages/stable/` | Identical for the `immich` and `full` test clusters |
| Add `packages.stable` and `packages.experimental` beside the short names | Identical for `immich`, `full`, `auto`, and `auto2` |
| A cluster that sets `availablePackages = packages` | Identical. The two extra keys are skipped |
| Use `packages.experimental.immich`, a copy of the stable package | Identical to the stable one. Graduation redeploys nothing |
| Ask for `packages.experimental.valkey`, which is stable only | Fails with the error above |

The package's folder never reaches cluster state. `kix.run/package` and the
PackageInstance record carry the instance name the user chose.

Not tested:

- The three packages that render Helm charts.
- A stable and an experimental package of the same name in one cluster.
- The repository's own checks, which still pointed at the old path.

## Work, in order

All of this ships in 0.10.0, together with the contract changes in doc 166.
The 0.10.0 release that was open on 2026-11-11 was closed without merging,
and its change records stay unreleased on `main` until then.

### Step 1: the move, with no rule change

- Move every package to `kix/packages/stable/`.
- Build the package set in one helper. Three places build it today:
  `flake.nix`, `kix/flake.nix`, and `kix/lib/mkFlake.nix`.
- Update the paths in `kix/package-eval.nix`, the unit tests that import
  packages by path, `scripts/vendor-crds.py`, and the skills that cite
  package files.
- Update the change-record check, which requires each name in `packages` to
  be a folder directly under `kix/packages/`
  (`scripts/change_records/__init__.py`, `check`).
- Move the contracts in the same step (doc 166).

Step 1 breaks no user. Clusters name packages through `packages`, and the
experiments show the output does not change.

### Step 2: the experimental level

Built:

- `kix/packages/experimental/`, `kix/contracts/experimental/`, and the merged
  sets, in `kix/lib/core/levels.nix`.
- Change records name an experimental package as `experimental/<name>` and
  an experimental contract as `kix.contracts.experimental.<name>`. A
  breaking record that names only those gives a patch release (`bump`) and
  is listed under "Breaking in experimental packages and contracts".
- `kix upgrade` matches a record for `experimental/<name>` against an
  instance called `<name>`.
- `kix list packages` shows an experimental package as
  `experimental.<name>`.
- A unit test refuses a stable package that reads
  `kix.contracts.experimental`.
- The patch rule is reworded in `CLAUDE.md`, the `CHANGELOG.md` header, and
  `changes/README.md`.

Two things turned out differently from the plan:

- **`packages.experimental` cannot be walked.** It holds an error for every
  stable name that has no experimental package, which is how a graduated
  name gets its message. Code that walks the experimental packages reads
  `kix/packages/by-level.nix`. `packages.stable` holds only packages.
- **`kix lib update` prints nothing new.** Kix builds a library only when
  Kix's patch is at least the library's, so a project needs the newer Kix
  before the newer library, and `kix upgrade` lists the change records in
  the range when Kix moves. A project that upgrades Kix first and runs
  `kix lib update` on a later day sees no list at that point. That gap is
  listed under "Not built".

Not built:

- The check that builds every package skips experimental packages.
- `scripts/change-kind.py` has no rule for clusters that use experimental
  packages.
- `kix lib update` does not list the experimental breaks between the old
  and the new library.

## Deferred

- **Narrowing what a reader receives.** Kix could hand a package only the
  fields of the contract it takes, so a stable package cannot read the extra
  fields an experimental publisher offers. Until then, review catches a
  stable package that reads beyond its contract. Not checked: how much
  packages use from a dependency beyond its contract fields.
- **Which packages start as experimental.** Decided when step 2 lands.

## Open questions

1. **Do experimental packages get docs pages?** If yes, the page should say
   what the level means.
2. **Which checks apply to experimental packages?** Proposal: the check that
   builds every package applies from the first day, and the review checklist
   may be looser.
3. **Private packages.** A private package that reads an experimental
   contract breaks in patch releases. Lithus should know which contracts
   its packages read before step 2 lands.
4. **Security fixes.** A fix ships only in the newest release (doc 164
   §1.3). A user of an experimental package may have to accept a break to
   get one.

## Alternatives considered

- **A `meta.stability` field and an opt-in list in the cluster.** Rejected.
  It needs a new field, a new option, and a check that ties them, and a
  package cannot be stable and experimental at once, which rule 6 needs.
- **A separate `experimental` input beside `packages`.** It keeps `packages`
  a flat set, but adds a third input to hand around. Rejected as less clean.
- **A forwarding name after graduation.** Rejected. A later rework under the
  same experimental name would move users onto it without their choosing.
- **A sibling folder, `kix/packages-experimental/`.** Rejected in favour of
  two folders under `kix/packages/`, which treats the levels the same way.
- **A label only, with the patch rule unchanged** (the review of this
  proposal against doc 164 recommended it). Rejected. Experimental packages
  would still raise the minor for every break, so the label would change
  nothing about releases.
- **"Still works with a warning" in a patch, removed at the next minor.**
  Rejected for packages that change this often. Each change needs a shim
  written and later removed, and doc 164 §1.2 decided against shims.
