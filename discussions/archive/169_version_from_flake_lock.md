# 169: Take the Kix version from flake.lock

**Status:** Implemented (kix#88, kix-examples#9, kix#90, 2026-11-13)
**Related:** `168_0_10_cleanup.md`, `163_cli_install_versions_and_upgrades.md`
**Supersedes:** the part of 163 where `kix.toml` names the project's Kix

## Problem

A Kix project records the version of Kix it uses in three places:

| Place | Who reads it | What for |
|---|---|---|
| `kix.toml`: `kix = "0.10"` | the launcher (`cli/kix-cli/src/select.rs`), before clap parses | which Kix program runs |
| `flake.nix`: the library input's URL | Nix | where the Kix library comes from |
| `flake.lock`: the library input's lock | Nix | exactly which library was fetched |

All three say one thing. They can disagree, so Kix carries code whose only job is to make them agree or to explain why they don't:

- the program-to-library compatibility rule in `cli/kix-core/src/version/policy.rs` (same minor, Kix patch at least the library's), and its "library 0.9.2, but this is Kix 0.10" error;
- `cli/kix-core/src/pin_library.rs` (1,136 lines), which finds the library input, edits its URL, and re-locks;
- the repair mode of `kix upgrade --to <the version the project is on>`, added in 0.10 to replace `kix lib update`;
- the `library-input` setting in `kix.toml`, and the errors for "no input named kix or kixpkgs" and "both exist";
- choosing the newest patch of a minor (`kix = "0.10"`), and the rule that a patch release may add a Helm version but never remove one.

The kind test of 0.10's stage 2 found the cost. A project with `kix = "0.10.0-rc.3"` in `kix.toml` and the 0.9.2 library in `flake.lock` failed to build, and the error said to run `kix upgrade --to 0.10.0-rc.3`. `kix upgrade` read `kix.toml`, decided the project was already on that version, and took the repair path. It re-pinned the library without the builds or the 0.9-to-0.10 breaking-change notes. Two pieces of code decide which version a project is on, and they disagree. The Lithus monorepo's `flake.nix` carries a comment telling engineers to "move the tag and kix.toml" together.

## Proposal

`flake.lock` is the one place a project names its Kix. Kix reads it to choose which Kix runs. Kix no longer checks a lock against the program, because it chooses the program from the lock.

### Rules

1. **A Kix project has a `flake.lock`.** Without one, Kix stops: "This project has no flake.lock. Run `kix upgrade --to <version>` to pin the Kix library and create it."
2. **The library is a direct input of the project's flake, named `kix`.** Kix looks for no other name and no nested input. `library-input` goes, along with the errors about `kixpkgs`.
3. **The input pins a release tag, `v<version>`.** That covers `github:kix-run/kix/v0.10.3`, `git+ssh://...?ref=refs/tags/v0.10.3`, or any other URL whose lock records that tag. That tag is the project's Kix version, exactly. An input with no tag stops with "flake.nix uses the Kix library without a version. Run `kix upgrade --to <version>` to pin one."
4. **Development mode.** When the `kix` input is a local path or a branch, or the project's `kix.toml` sets `library = "self"` to say its own flake provides the library (as this repository does), the project has no release version. `library` takes two values: `"input"`, the default, which means the library is the input named `kix` and its tag in the lock is the version, and `"self"`. Any other value is an error that names both. Kix runs the installed Kix, says once that it is using a development library, and compares nothing.
5. **Exact versions only.** A lock pins one tag, so ranges such as `"0.10"` and the newest-patch choice go away.
6. **`kix =` in `kix.toml` is refused** with an error id that says the version now comes from `flake.lock`. The refusal stays for one minor release, as `CLAUDE.md` requires. `kix.toml` keeps `builder`, `min-age`, and the other settings.

### How the launcher chooses

`flake.lock` is JSON, so the launcher reads it without Nix:

1. Find the root node's `kix` input. If there isn't one, or the file doesn't exist, apply rule 1 or rule 2.
2. Read the input's locked `original`. A `v<version>` tag gives the version. A path or a branch means development mode.
3. Run that exact version, installing it if needed, with today's hand-over (`select.rs` already does this for `kix.toml`).

There are no network calls and no Nix evaluation. A plain commit, with no tag, is not supported, because turning it into a version would need the release index.

### One check stays

A lock can fall behind `flake.nix` when someone edits the tag by hand. Before Nix evaluates anything, Kix compares the release tag in the url of the `kix` input in `flake.nix` with the tag in `flake.lock`, finding the url the way `kix upgrade` does when it pins. On a mismatch it stops with "flake.nix asks for Kix Y, but flake.lock pins Kix X. Run `kix upgrade --to Y`.", so Nix never rewrites the lock. `kix upgrade` then sets `flake.nix` back to X and runs its usual flow from X to Y. When Kix cannot find the url (an attribute-set input, a changed repository, or a second url still on X), the library's own version is compared with the running Kix after evaluation, with "flake.lock pins Kix X, but flake.nix now asks for Y." Neither comparison is a compatibility rule, and neither repairs anything.

### Upgrading

`kix upgrade --to X` keeps its builds, its breaking-change notes, and its required stops. It changes the tag in `flake.nix`, re-locks, and is done. The repair mode goes away: if the lock already pins X there is nothing to do, and if it pins anything else that is an upgrade. The version the project is on always comes from `flake.lock`, so the bug the kind test found cannot occur.

## What goes away, what stays

| Goes | Stays |
|---|---|
| `policy::library_compatible` and its errors, except the check above | the hand-over between Kix versions (`select.rs`) |
| the repair mode of `kix upgrade --to` | `kix upgrade`: builds, notes, required stops |
| `library-input`, and both input names | editing the tag in `flake.nix` during an upgrade (smaller: one input name, no `follows`) |
| `kix =` in `kix.toml` (refused) | `builder`, `min-age` and the rest of `kix.toml` |
| newest-patch choice and version ranges | development mode, now explicit |
| the "a patch may add a Helm version" rule | |

## Cases where a lock is missing or unusual

| Case | What happens |
|---|---|
| New project, first build | Rule 1's error. `kix upgrade --to X` writes the tag and creates the lock. |
| The team does not commit `flake.lock` | The file exists locally, so Kix runs. `kix doctor` warns when Git does not track `flake.lock`, so the version does not drift between clones. |
| This repository and library development | Development mode (rule 4). |
| The docs capture pipeline, which deletes `flake.lock` | It locks the `kix` input to its store path with an override, and stops deleting the file. |
| A bare `github:kix-run/kix` | Rule 3's error. `kix-examples` adds a tag. |

## Migration

Every breaking change below makes Kix stop with an error that names the fix. None fails silently.

- Projects with `kix =` in `kix.toml` get the refusal from rule 6. They delete the line, because the lock already holds the version.
- Projects whose library input is named `kixpkgs` get rule 2's error, which names the rename. Lithus's monorepo renames `kixpkgs` to `kix`. It already pins a tag on its mirror, so rule 3 holds.
- `kix-examples` renames its input and adds a tag.
- Change records: one `error` record for the refused `kix =` and the input name, and one `changed` record for upgrade.

## Alternatives considered

**Ship the library inside the Kix release.** Kix carries the library in its signed archive and points the `kix` input at its own copy with `--override-input`. The version then lives only in `kix.toml`, and a program and its library match by construction. Measured on 2026-11-13: `kix/` is 20 MB (the library itself is 2.4 MB; 14 MB of the 17 MB of packages are vendored CRDs). It compresses to about 1.1 MB with zstd, xz, or brotli alike, and zstd unpacks it in 0.01 s. At ten times the packages, about 11 MB to download and 170 MB unpacked. That would need packages fetched one at a time, by content hash, lazily, as Helm does with charts. We did not choose it now, because it changes too much at once. Plain `nix` and editor tooling would read a lock that disagrees with the library Kix uses, and Kix would override an input the user declared, which surprises Nix users. It stays open as a later step. Nothing in this proposal rules it out.

**Keep `kix.toml` as a fallback when the lock has no version.** Rejected. A fallback is a second source again, and requiring a lock and a tag costs one command once.

**Repair only on the same minor** (`policy::project_version`, built and backed out on branch `rc4-upgrade-fixes`). Rejected. One `--to` value would still mean two things, decided by state the user cannot see.

**A separate `kix sync` command for the repair.** Rejected. It adds a command one release after `kix lib update` was removed, for a state this proposal makes impossible.

**At most one minor per `kix upgrade`, with required stops only at `x.y.0`.** It would shrink the upgrade planner. Rejected for now: minor releases come quickly at present, and running `kix upgrade` three times in a week is a real cost.

## Sequencing

This changes the CLI surface `kix upgrade` and `kix.toml` expose, so it lands before the two elegance and DX review rounds that 168 ends with, and before 0.10.0. The rc.4 bug fixes from the stage 2 kind test go ahead as they are, except the minor-jump repair item, which this replaces.

## Open questions

1. Should the refusal of `kix =` accept a value that equals the lock's tag for one release, so a project can keep the line while it upgrades? Leaning no: one clear error is simpler.
2. How does `kix self` (outside any project) pick a version? Today it uses the installed default. This proposal does not change that.
3. Which Nix version does the Kix runtime bundle? The Git-format tarball cache (Nix 2.20+) matters only for the bundled-library alternative, but should be recorded.
