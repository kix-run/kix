# 162: Project builders: Kix, Nix, and remote

**Status:** Draft (plan)
**Related:** `161_rootless_evaluation_bundled_runtime.md`
**Branch:** `feat/rootless-runtime` (PR #319)

## Goal

Doc 161 makes Kix build every project with its own Nix and its own store.
Some projects need the machine's Nix instead. Luca's project is one: it
uses its own store, binary caches, and remote builders, and it needs a plain
`nix build` of a cluster to work. Doc 161 left "use the machine's Nix" out of
scope. Branch `feat/rootless-runtime` removes the route those projects use
today, so it cannot ship as 0.8 without this plan.

A project chooses how it is built with one setting. The setting has three
values: `kix` (the default, doc 161's design), `nix` (the machine's Nix, as
Kix worked before the branch), and `remote` (a build service that speaks an
open API). This plan delivers `kix` and `nix` in 0.8 and reserves `remote`.

## Decided

These were settled with Adam on 2026-11-07.

- **The builder belongs to the project, not to the person.** Everyone who
  builds a project, and its CI, uses the same builder. So the two local
  builders do not have to give identical output. Each project gives the same
  output on every machine, because its `flake.lock` pins everything a build
  reads.
- **The setting lives in `kix.toml` at the project root.** The CLI must know
  the builder before it starts Nix, and reading `flake.nix` needs Nix. Nix
  is lazy, so Kix could ask its own Nix for one attribute. But that copies
  the project and its Kix input into Kix's store on every machine, including
  machines that use the `nix` builder. A TOML file costs nothing to read. The
  library reads the same file with `builtins.fromTOML`.
- **No flag or environment variable chooses the builder.** A choice that
  must be the same for everyone belongs in a committed file. The one
  exception is a test override for Kix's own CI (section 4).
- **The remote builder is a protocol, not a product.** `kix.toml` names a URL
  and a signing key. Kix Enterprise is one server that implements the API.
  Anyone may write another, and Kix ships a reference server.
- **The `nix` builder ships with 0.8.** Without it, 0.8 breaks every project
  that relies on the machine's Nix or on `nix build`.

## Findings that shaped the plan

Four research agents checked these on 2026-11-07. The test files are in the
session scratchpad, not in the repo.

- **Kix cannot put its own Helm renders into the machine's store.** In a
  store that a Nix daemon owns, a user who is not in `trusted-users` can add
  content-addressed paths (`nix-store --add-fixed` works), but cannot add an
  input-addressed path: `--load-db`, `nix-store --import`, and
  `nix copy --no-check-sigs` were all refused in a test. A render's path is
  input-addressed. Being a trusted user is close to being root, so asking
  for it is not an answer.
- **Nix can run Helm itself in the machine's store.** An untrusted user can
  build an ordinary derivation through the daemon and read its output during
  evaluation (import from derivation). Tested on Linux.
- **Kix's own store can run builds on Linux but never on macOS.** Nix 2.35
  builds in a store outside `/nix/store` only inside a Linux user namespace
  (tested with the bundled static Nix). On macOS it refuses outright
  (`derivation-builder.cc`: "building using a diverted store is not supported
  on this platform"). So the `kix` builder keeps the placeholder route of
  doc 161 on every platform.
- **Our charts render the same output every time.** None of the five charts
  Kix packages use reaches `randAlphaNum`, `genCA`, `now`, or `lookup` with
  the values Kix passes. Two gaps are logged in `housekeeping/`: `importChart`
  leaves the Kubernetes version to Helm's default, and Cilium's user values
  can turn on certificate generation.
- **The converters match.** `cli/kix/src/eval/helm_yaml.rs` reproduces
  `yq eval-all -o=json '[.]'` from yq 4 scalar for scalar. A test checks
  it against yq's output for every chart in the repo (commit bbecabfd,
  fixtures in `cli/kix/tests/fixtures/helm-yaml/`). So the `nix` builder can
  use `yq-go` from the project's nixpkgs.
- **The `nix` route already existed on this branch.** Phase 3 of doc 161
  (commit e9e291ef) rendered every chart in a real derivation with the
  pinned Helm 4.3.1 from `helm-versions.json` and `yq-go` from nixpkgs,
  before phase 4 moved rendering into the CLI. Its `helm.nix` is the
  starting point for section 3.
- **Pipe operators need Nix 2.24 or later.** Lix names the feature
  `pipe-operator` and parses it with a different precedence.
- **`nix store info --json` reports `trusted`** (Nix 2.15 and later, under
  `nix store ping` in older releases). The `nix` builder does not need it,
  but `kix doctor` can show it.

## Design

### 1. `kix.toml`

```toml
# Optional. Without this file the builder is "kix".
builder = "nix"        # "kix" | "nix" | "remote"
```

The file sits beside `flake.nix` in the directory `--flake` names (a local
path, as `KixEvaluator::flake_path` requires today).

- The CLI reads it before it evaluates anything. This adds a TOML parser
  crate to the workspace; none is there today.
- An unknown key or value is an error that names the keys and values this
  Kix version knows and says to check the spelling or upgrade Kix. This
  makes `builder = "remote"` safe to reserve: Kix 0.8 refuses it with "this
  version of Kix cannot use a remote builder".
- `mkFlake` reads `inputs.self + "/kix.toml"` when the file exists and
  exposes the parsed settings as `legacyPackages.<system>.kixConfig`.
- **The file must be tracked by git.** Nix's git fetcher skips untracked
  files, so a new `kix.toml` is invisible to the library until someone runs
  `git add`. Kix no longer runs git, so it checks agreement instead: each
  evaluation also reads `kixConfig.builder`, and when it differs from the
  file on disk Kix stops with "kix.toml is not visible to Nix. Run
  `git add kix.toml`."

Adding the file and the setting is not a breaking change. A project without
the file builds as it does on the branch today.

### 2. Two layers in the CLI

**`Builder`.** The trait `NixBackend` in `cli/kix/src/eval/evaluator.rs:94`
already describes what a builder does: evaluate a cluster, list clusters,
list packages, and list a cluster's packages. `CliNixBackend` implements it
for real and `MockNixBackend` for tests. Rename it `Builder`. Each builder in
`kix.toml` is one implementation. Commands such as `diff`, `deploy`, and
`bundle` talk to the trait and never ask which builder is in use.

Nothing in the trait may assume the work happens on this machine. A result
names store paths. The local builders find those paths in a local store. A
remote builder must make them available locally before it returns
(section 5).

**Nix runner.** The two local builders differ in which Nix they start and
which store it uses. That is decided once, next to `runtime::runtime()`:

```rust
enum NixRunner {
    /// Kix's own Nix against Kix's own store (`kix` and `remote`).
    Bundled { root: PathBuf },
    /// The `nix` on PATH, with the user's settings and `/nix/store`.
    System,
}
```

| Place | Change |
|---|---|
| `runtime.rs:327` `tool()` | For `Nix` and `NixStore` under `System`, take the program from PATH and skip `use_store` and `init_store`. Helm, kubectl, and sops always come from the runtime. |
| `eval/nix.rs:46` `command` | Unchanged. It already passes `--extra-experimental-features` on each call. |
| `eval/nix.rs:243` `eval_with_helm` | Under `System`, never run the render loop. A `kix-helm` placeholder there is a bug, reported as one. |
| `eval/nix.rs:408` `activation_index_attr` | Choose `kixClusters` or `kixClustersNix` by builder (section 3). |
| `eval/store.rs` `store_root`, `real_path`, `disk_path`, `canonicalize`, `follow_into_store` | Take the runner's root as an `Option`. `None` means `/nix/store`, and `real_path` already returns the path unchanged then. |
| `eval/cache.rs:172` | Key the evaluation cache on the builder and runner, not only the store root. |
| `commands/doctor.rs` | Show the builder and where it came from. Under `System`, show the Nix version, whether `allow-import-from-derivation` is on, and `trusted`. |
| `KIX_STORE_ROOT` | An error under `System`, because it would not apply. |

The research found every other caller of the Nix programs and the store
helpers already goes through these functions: `kix-bundle/src/write.rs`,
`diff.rs`, `secrets.rs`, `build_files.rs`, `derivation.rs`,
`cli_backend.rs`, `store_graph.rs`, `health.rs`, `library.rs`, and
`add_gc_root`, which works through the daemon.

**Checks before the `nix` builder runs.** `nix --version` must report Nix
2.24 or later. Lix is refused with a message that says so, until someone
needs it and we test it. A Nix configured with
`allow-import-from-derivation = false` cannot render a Helm cluster, and Kix
says which setting to change.

### 3. Helm under the `nix` builder

Nix runs Helm in an ordinary derivation, as phase 3 of the branch did
(commit e9e291ef). Compared with `main`, two changes keep a chart's meaning
the same under both builders:

- **The Helm binary is the release Kix pins**, not `pkgs.kubernetes-helm`.
  `helmVersion = "3"` or `"4"` means the same release under both builders.
  The derivation downloads the official tarball with `pkgs.fetchurl`, using
  the URLs and hashes `kix/lib/helm-versions.json` already holds for the
  runtime (`cli/runtime/runtime.nix:76-90` shows how). That file also has an
  `x86_64-darwin` entry, which the `kix` builder cannot use.
- **The flags come from the same spec.** `helmTemplateDerivation` already
  builds a spec attribute set (`releaseName`, `namespace`, `includeCrds`,
  `includeHooks`, `kubeVersion`, `extraFlags` as separate arguments). The
  `nix` route turns that same set into the `helm template` command line, so
  the two routes cannot pass different flags.

The conversion uses `pkgs.yq-go` from the project's nixpkgs, which the Rust
converter was written to match.

**Fetching** stays a fixed-output derivation with the same name
(`helm-chart-<name>-<version>`) and hash, so a chart has the same store path
under both builders. Under `nix` it gets a real builder that runs
`helm pull` with the newest pinned Helm.

**In the library**, `helm.nix` takes a `helmRoute` argument
(`"placeholder"` or `"nix"`) next to its existing `readRender`. `mkFlake`
imports the library twice and resolves the clusters twice. Evaluation is lazy,
so only the copy a command forces costs anything. It exposes:

| Output | Route | When |
|---|---|---|
| `legacyPackages.<system>.kixClusters.<name>` | placeholder | always (unchanged) |
| `legacyPackages.<system>.kixClustersNix.<name>` | nix | always |
| `legacyPackages.<system>.kixConfig` | none | always |
| `packages.<system>.cluster-<name>-activation` | nix | only when `kix.toml` says `builder = "nix"` |

The last row brings back the output the branch removed, for `nix` projects
only. Plain `nix build .#cluster-<name>-activation` works there as it did on
`main`. A `kix` project keeps doc 161's behaviour: that attribute is missing.

**`nix flake check` across systems.** `nix flake check` checks only the
current system unless it gets `--all-systems`. With that flag, import from
derivation needs a builder for every system the flake lists, as it did on
`main`. The docs for `nix` projects should say so.

### 4. Tests and CI

- **Library.** Evaluate the Helm test cluster and `ludo-kind` under both
  routes. Compare the activation index of each pair. They are expected to be
  equal, because the Helm release, the flags, and the converter output match.
  A difference fails the job and names the resource that differs. We
  promise users that each builder is consistent, not that the two agree, but
  agreement is the cheapest way to catch a route that has gone wrong.
- **CLI.** Kix's own CI needs both builders on the same test clusters, so a
  test-only environment variable, `KIX_TEST_BUILDER`, overrides `kix.toml`.
  It is not documented for users.
- **New CI jobs:** `nix-builder` on Linux and macOS with Nix installed by
  the installer action. Each runs `kix build` and `nix build
  .#cluster-<name>-activation` on a Helm cluster, as a user that is not in
  `trusted-users`.
- **Unit tests:** `kix.toml` parsing and refusals, the `kixConfig` mismatch
  message, the Nix version and Lix checks, and the runner choice in `tool()`.

### 5. The remote builder (later)

Reserved in 0.8. Outline only, so the 0.8 code does not block it:

```toml
builder = "remote"

[remote]
url = "https://builds.example.com"
signing-key = "builds.example.com-1:Abc...="   # public, safe to commit
```

- **Credentials never go in `kix.toml`.** A token comes from an environment
  variable, and later from `kix login`.
- **The API is the `Builder` trait over HTTPS.** List clusters, list
  packages, and evaluate a cluster. The client sends the git-tracked files,
  or a git URL and commit the server can fetch, and the server can skip
  files it already holds. Every request carries an API version, so a client
  and server that do not understand each other say so. The spec is a
  published, versioned document.
- **Results travel as a Nix binary cache.** The server publishes its outputs
  in the standard binary cache format, signed with its key, and Kix copies
  them into its own store. Attic, Harmonia, Cachix, or an S3 bucket can
  serve that format today, so a third-party server need not write any
  transfer code.
- **Trust.** Kix writes the settings of its own store, so it can trust the
  `signing-key` from `kix.toml` without an administrator. A remote project
  therefore uses the `Bundled` runner locally.
- **A reference server ships in Kix** (`kix serve`): it answers the API by
  running the `kix` builder. Kix's CI tests the remote builder against it,
  and people can host it themselves. Kix Enterprise is one more
  implementation.

## Phases

Each phase is one pull request into `feat/rootless-runtime`, and the
branch stays green after each.

1. **`kix.toml` and the CLI layers.** Parse and validate `kix.toml`,
   refuse `remote`, rename `NixBackend` to `Builder`, add `NixRunner`,
   pass the store root as an `Option` through the store helpers, key the
   cache on the builder, and extend `kix doctor`. The `kix` builder behaves
   exactly as it does now. The `nix` value parses and is refused as "not
   ready" until phase 2.
2. **The `nix` builder.** The `nix` Helm route in `helm.nix`, the second
   copy in `mkFlake`, `kixClustersNix`, `kixConfig`, and the conditional
   `cluster-<name>-activation` output. In the CLI: the `System` runner, the
   attribute choice, the agreement check, and the version, Lix, and
   import-from-derivation checks.
3. **CI and the comparison.** The route comparison, the `nix-builder` jobs
   on Linux and macOS, and `KIX_TEST_BUILDER`. A list of docs follow-ups
   for the writer of the docs: `kix.toml` reference, the builder choice in
   the install and Helm pages, `kix doctor`, the CHANGELOG lines, and
   `cli/README.md`.
4. **Later, after 0.8:** the API spec, the `remote` builder, and
   `kix serve`.

Size, from the code survey: about 12 to 15 Rust files and 400 lines plus
tests, about 150 lines of Nix, and two CI jobs.

## Risks

- **Two Helm routes.** Every change to how Kix runs Helm must be made twice.
  The spec attribute set both routes read, and the comparison job, keep
  them from drifting.
- **yq drift.** A project's nixpkgs could carry a yq release that prints a
  scalar differently. That changes only `nix` projects, and only when they
  update nixpkgs, which already changes their build. The comparison job
  runs on our pinned nixpkgs and would catch it there.
- **Import from derivation is slow.** Each uncached chart is a build during
  evaluation, as it was on `main`.
- **A user's Nix setup.** Old Nix, Lix, or import from derivation turned off.
  Each gets a check and a message that names the fix.

## Questions for Luca

1. Does your project need `nix build .#cluster-<name>-activation`, or another
   flake output, to work without `kix`? The plan assumes yes.
2. Is the Helm release Kix pins acceptable, or does your project need the
   Helm from its own nixpkgs?
3. Which Nix do you run, and which version? Is any machine on Lix?
4. Do you build on macOS?

## Out of scope

- **Real builds in Kix's own store on Linux.** They work, but macOS cannot do
  them, so the `kix` builder keeps one route on every platform.
- **A per-person builder choice.** The builder belongs to the project.
- **Pinning render output by hash in a lock file.** Considered as a way to let
  one Helm route serve both stores. A per-project builder removes the need.
