# Versioning, change records, and stability levels

Claude Code loads this file together with `CLAUDE.md`. Other documents cite
these sections as `CLAUDE.md` § Versioning and breaking changes and
`CLAUDE.md` § Stability levels.

## Versioning and breaking changes

Kix uses semantic versioning and is still below 1.0. A breaking change to anything stable may go in a minor release (0.5 to 0.6), never in a patch release. An experimental package or contract may break in any release (see Stability levels below). Prefer a clean design to keeping old behavior. Do not count a change as breaking just to be safe.

A change is breaking when a user who upgrades must change something, or gets a different result from the same definition. These are breaking:

- removing or renaming a CLI command, flag, or package option, or changing an exit code
- removing or renaming a field or event in JSON output (`-o json`, `--log-format json`), or changing what a value means. This also moves the `SCHEMA_VERSION` of the plan document or the deploy log.
- a change to the `kix` Nix library or to the package shape `{ scope, lib }: { meta, options, build }` that makes an existing package or cluster definition fail or work differently
- a change to the state Kix writes into a cluster (Activation records, `kix.run/*` annotations, PackageInstance, and Kix's CRDs) that makes existing state read differently
- a change to what a package deploys that the user has to act on, such as moving where it keeps its data

A new check that refuses a definition is breaking only when that definition deployed and ran before. When the definition already failed at deploy, for example because Kubernetes rejects the object, the check is a `fixed` record: the user was already broken and now learns at build time. The record still says what to change. A definition that deployed and did the wrong thing without failing, such as a selector that matches no pod, is not this case, and its check is an `error` record. The Change kind check cannot tell the two cases apart, so say in the pull request description which one applies and why.

Adding something is not breaking. That covers a new command, flag, option, field, event type, annotation, or field in cluster state. Programs that read Kix's JSON output or cluster state must skip fields and event types they do not know, and the JSON schemas say so. The Rust crates are not a public API.

There are two kinds of breaking change, each a kind of change record (below) with its own heading in `CHANGELOG.md`:

- `error`, `### Breaking (shows an error)`: Kix stops with an error that says what to change. For example, a build fails until a package sets a new value. A user cannot miss this kind.
- `silent`, `### Breaking (no error)`: nothing fails, but the result is different. For example, a package now looks for its files in another folder. A user can miss this kind, so it is the more serious one.

Where you can, turn a breaking change with no error into one that shows an error. For example, make the build refuse the old setting and name the new one. This is a goal, not a rule: do it when the cost is reasonable.

Package options, library functions, and CLI flags have no deprecation period. A release may warn about an option before a later release removes it, but it does not have to, and the removal is the `error` record. The records in `changes/0.9.1/` that say an option "still works with a warning, and 0.10 removes it" were written before this rule, and 0.10 keeps that promise. The release that removes or renames one refuses the old form with an error that names the new one and prints the change record's id, such as `[K0001]`. That refusal stays for at least one minor release.

Each breaking change's record says what users change when they upgrade. A change that needs no action, but that users should know about, is a `note` record, listed under `### Upgrade notes`. For example, the first deploy after an upgrade applies many objects again, or restarts some pods once.

One rule holds even before 1.0: a Kix release reads the cluster state written by any release from the last six months, or by the previous minor release, whichever covers more. Cluster state outlives the binary that wrote it, so a change to that state keeps a way to read the old form for that long. A change that cannot keep this promise sets `required-stop = true` on its record: clusters must be deployed with that release before they upgrade further. `kix upgrade` stops at that release, and `kix deploy`, `kix rollback`, and the operator refuse a cluster that would skip it (the release skill adds the version to `REQUIRED_STOPS` in `cli/kix/src/cluster/stops.rs`). Required stops should be rare. The test `cluster_state` in `cli/kix/src/cluster/state_fixtures.rs` reads the objects kept in `cli/kix/tests/fixtures/cluster-state/<version>/`. A release adds a folder there only when one of its change records has `state = true`.

A project names its version of Kix in `flake.lock`: the release tag `v<version>` of its flake input named `kix` (`cli/kix-core/src/flake_lock.rs`). Kix reads that tag before it parses its arguments, and runs or installs exactly that version, so a project's Kix and its Kix library have the same version. A `kix` input on a local folder or a branch, or a project whose `kix.toml` sets `library = "self"` (this repository), uses a development library: Kix runs the version the user started and compares nothing. The one check left, that the library a project evaluated is the running Kix, lives in `cli/kix-core/src/version/policy.rs`, and no other code compares Kix with a library. `kix.toml` names no version and refuses a `kix` key. A project may hold clusters on several versions (`cli/kix-core/src/versions.rs`): each version is one more input of `flake.nix`, such as `kix-stable`, and the `[versions]` table of `kix.toml` lists the clusters under each input. The outputs of `flake.nix` read only `kix`, and Kix replaces that input with the cluster's own for the evaluation, so no version of Kix evaluates another version's library. The input `kix` pins the newest version in the project. Kix downloads only Kix itself, never the programs it runs, which arrive inside the signed release archive.

Every pull request that changes something a Kix user sees adds a change record: one file, `changes/<name>.md`, usually named after the branch. Its TOML header gives the `kind` (`error`, `silent`, `note`, `security`, `added`, `changed`, or `fixed`) and what the change touches, and its text is the line users read. `changes/README.md` has the format, and `scripts/change-records.py check` validates it. Do not edit the release sections of `CHANGELOG.md`: the release writes them from the records and moves the records to `changes/<version>/`. The Changelog workflow checks every record's format, and checks that pull requests that change `cli/` or `kix/` add one. Label a pull request `no-changelog` when nothing a user sees changes, such as tests, CI, or an internal refactor. To cut a release, use the `release` skill (`.claude/skills/release/SKILL.md`).

The Change kind workflow (`scripts/change-kind.py`) builds a set of clusters twice: at the pull request's base, and with the pull request's library and the base's cluster definitions (`clusters/`). It then checks the records against what changed. Because the definitions come from the base, fixing `clusters/` in the same pull request does not hide a change. A cluster that builds at the base and fails with the pull request's library needs an `error` record, and the error message must contain its id. A cluster whose manifests change needs a record. Read the objects the check lists as changed, and choose the kind from what a user who upgrades gets. If they must act on the difference, the record is `silent`, not `fixed`. Say in the pull request description which kind you chose and why. A pull request that removes or changes a line of `cli/kix-cli/tests/snapshots/cli_surface.snap` (commands, flags, and their values) or a field of `cli/kix-cli/schema/` needs a record with a `cli` field. The check has two known limits. It sees only the packages that the clusters it builds use, so a change to a package none of them uses passes with no finding. Nothing checks that the kind in the record is right.

## Stability levels

A package, a contract, or a module is stable or experimental. The folder it is in sets the level, and the name a user types shows it.

| | Stable | Experimental |
|---|---|---|
| Package folder | `kix/packages/stable/<name>/` | `kix/packages/experimental/<name>/` |
| In a cluster | `packages.<name>` (also `packages.stable.<name>`) | `packages.experimental.<name>` |
| Contract file | `kix/contracts/stable/<name>.nix` | `kix/contracts/experimental/<name>.nix` |
| In a package | `kix.contracts.<name>` (also `kix.contracts.stable.<name>`) | `kix.contracts.experimental.<name>` |
| Module file | `kix/modules/stable/<name>.nix` | `kix/modules/experimental/<name>.nix` |
| In a cluster | `kix.modules.<name>` | `kix.modules.experimental.<name>` |
| May break in | a minor release | any release |

- A stable package reads only stable contracts and imports no file of an experimental package. An experimental package may read both. The test `levels-stable-packages-read-stable-contracts` checks this. A file two packages share lives in the stable one when either is stable.
- A package becomes stable once it has run in production long enough to settle, such as in more than one Lithus cluster. New packages start experimental.
- `availablePackages = packages` offers stable packages only. A cluster names each experimental package Kix may add: `packages // { inherit (packages.experimental) cert-manager; }`.
- An experimental package may publish a stable contract. A stable package can then take it as a dependency.
- Graduation is a folder move, in any release. It changes one thing that is deployed: `spec.package` on each PackageInstance of the package goes from `experimental/<name>` to `<name>`, so the Change kind check asks for a record. After it, the experimental name fails with an error that gives the stable one. Do not add a forwarding name.
- An experimental package may have the name of a stable package. It is a rework of that package and replaces it in a minor release.
- No package or contract is named `stable` or `experimental`.
- The library has no experimental level. A break to a library function needs a minor release.
- A change record names an experimental package as `experimental/<name>` in `packages`, and an experimental contract as `kix.contracts.experimental.<name>` in `library`. A breaking record that names only those gives a patch release, and `CHANGELOG.md` lists it under `### Breaking in experimental packages and contracts`.

`kix/lib/core/levels.nix` builds the sets. `kix/packages/default.nix`, `kix/contracts/default.nix`, and `kix/modules/default.nix` list the folders. The old names of what moved to experimental in 0.10 fail with `[K0549]` (`kix/packages/was-stable.nix` and the lists in the two other loaders); remove them in 0.11. Adding a package or a contract is adding a folder or a file. Every contract file returns the result of `mkContract` (`kix/lib/vocab/contract.nix`), with the contract's own functions under `helpers` and its option set under `options`.
