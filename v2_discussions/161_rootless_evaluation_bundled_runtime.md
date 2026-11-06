# 161: Rootless evaluation with a bundled runtime

**Status:** Draft (implementation plan)
**Related:** kixpkgs#315, `120_compiler_theory_mapping.md` (Helm render caching)

## Goal

A user can install Kix on a Mac or Linux machine and run `kix build`,
`kix plan`, and `kix deploy` without installing Nix, without root, and
without Kix downloading programs at run time. Every way of running Kix renders
Helm charts with the same Helm, so a laptop and CI produce the same activation
hash for the same definition.

## What is already settled

These were decided in the issue thread and in review on 2026-11-06. This
document does not reopen them.

- **The compiler runs without nixpkgs packages.** `kix/lib` evaluates with
  `pkgs = null`. No package in `kix/packages/` uses `pkgs`. Only Helm,
  `mkManifests`, and the activation wrapper in `mkFlake.nix` do.
- **The macOS runtime works.** A relocatable bundle of the cached `nix` closure
  (68 dylibs, 17 MB compressed) evaluated the example cluster on a Mac with
  `/nix` blocked and gave byte-identical output. The bundle script is in the
  issue thread.
- **Evaluation runs in pure mode.** Impure mode with a relocated store reads
  the real `/nix/store` first, so a developer's own store would leak in.
- **Programs ship beside the binary.** The release archive carries them in
  `libexec/kix/`. Kix never downloads a program. It does not embed them in the
  binary, and it does not unpack anything at run time.
- **`nix build` does not render Helm charts.** Kix renders charts itself. A
  cluster that uses Helm builds only through `kix`.
- **Several Helm major versions ship side by side**, starting with Helm 3 and
  Helm 4. A chart chooses one.
- **The list of bundled programs can grow, but only the Kix maintainers can
  add to it.** Users cannot add a program, because each program can change
  what Kix produces and the release must pin it.
- **The runtime also carries `kubectl` and `sops`.** Kix already runs both.
  Kix stops running `git` (section 2).
- **The `cluster-<name>-activation` flake output goes away.** Building a
  cluster means running `kix`.
- **Kix always uses its own runtime and its own store**, even on a machine
  with Nix installed. An option to use the machine's Nix may come later as an
  advanced setting. It is out of scope here.

## Facts checked against the code and caches

- CI never runs `nix build .#cluster-<name>-activation` directly. `kix build`
  runs it (`cli/kix/src/eval/nix.rs:208`), and the tests run `kix`. Two docs
  pages tell users to run it by hand, both for `kix diff --from`.
- The locked nixpkgs ships Helm 3.19.1. Nixpkgs unstable ships Helm 4.3.1 under
  the same attribute name. No single nixpkgs revision carries both majors.
- Static `nix` 2.31.3 for x86_64-linux and aarch64-linux is in
  cache.nixos.org. The aarch64-darwin static build is not, which is why macOS
  uses the dylib bundle.
- The two docs pages that run `nix build` by hand do it to save a build for
  `kix diff --from`. `kix bundle` and `kix diff --from-bundle` already do that
  job.
- A placeholder derivation works as a Helm render cache in pure mode. With
  `system = "kix-helm"`, evaluation stops at the missing output. After the
  output is written and registered with its real NAR hash through
  `nix-store --load-db`, the next evaluation reads it, and
  `nix store verify --no-trust` passes. A fake hash is not needed.
- Kix already runs other programs it expects to find installed: `kubectl`
  (`kix logs`, `kix pf`), `sops` (secret decryption), and `git` (compliance
  reports).

## Design

### 1. The runtime archive

```
kix-<version>-<target>/
  bin/kix
  libexec/kix/manifest.json
  libexec/kix/nix-2.31.3/bin/nix
  libexec/kix/nix-2.31.3/lib/*.dylib     (macOS only)
  libexec/kix/helm-3.19.1/bin/helm
  libexec/kix/helm-4.3.1/bin/helm
  libexec/kix/kubectl-1.35.0/bin/kubectl
  libexec/kix/sops-3.12.1/bin/sops
```

Every program sits in a directory named after its exact version. Libraries a
program needs live inside its own directory, so two versions of one program
never share or overwrite each other's libraries. Any program can ship in two
versions without a layout change. `manifest.json` is the only index. No Kix
code builds a path from a name and a version.

`runtime.nix` in this repo lists every bundled program, with its version and
source. The release build reads it, assembles `libexec/kix/`, and writes
`manifest.json` with the name, version, and SHA-256 of each file.

- `nix` comes from the pinned nixpkgs: `pkgsStatic.nix` on Linux, the dylib
  bundle of `pkgs.nix` on macOS.
- Helm, `kubectl`, and `sops` come from their upstream release binaries
  (get.helm.sh, dl.k8s.io, and the sops GitHub releases), pinned by URL and
  hash. No nixpkgs revision carries two Helm majors, and the upstream binaries
  are static Go programs on every platform, so packaging is a copy. The Helm
  versions come from `kix/lib/helm-versions.json` (section 5), so the runtime
  and the library cannot disagree.
- The macOS bundle script takes any program and writes it into its own
  versioned directory. Today only `nix` needs it.

### 2. Finding a program: `runtime::tool`

All code that starts a bundled program goes through one function, which takes
the program and the version the caller needs:

```rust
runtime::tool(Tool::Nix, Want::Shipped) -> Result<Command>
runtime::tool(Tool::Helm, Want::Exact("4.3.1")) -> Result<Command>
```

`Want::Exact` is for output that a version is part of, which today means Helm
renders: the version comes from the render spec, and a missing version is an
error, never a substitute. `Want::Shipped` is for everything else. It requires
exactly one shipped version of that program and fails if there are two, so
shipping a second version of a program forces every caller of it to state what
it needs. Callers that do not care about the version are not made to name one.

It looks for the runtime in this order and stops at the first match:

1. `KIX_RUNTIME_DIR`, for tests and unusual layouts.
2. `../libexec/kix/` relative to the running `kix` binary.
3. A directory compiled in at build time, for a Nix or Homebrew package of
   Kix.

If none has the files, Kix stops with an error that names the directories it
searched. It never falls back to a program on `PATH`. A fallback would let a
different Helm render the charts without anyone noticing.

At startup Kix compares `manifest.json` with the manifest compiled into the
binary. A mismatch means files from two releases were mixed, and Kix stops.
Kix does not hash the files on every run. `kix doctor` verifies the hashes.

`Tool::Nix` also sets the environment the bundled Nix needs: `NIX_STATE_DIR`,
`NIX_CONF_DIR` (a directory Kix writes with the experimental features it
needs), `NIX_USER_CONF_FILES=""`, and `NIX_SSL_CERT_FILE` (`/etc/ssl/cert.pem`
on macOS, the first CA bundle found on Linux).

Adding a program later takes one entry in `runtime.nix`, one `Tool` variant,
and moving that program's call sites to `runtime::tool`.

**`git` leaves instead of joining.** The compliance commands run `git` for two
facts: the commit (`rev-parse HEAD`) and whether the tree has uncommitted
changes (`status --porcelain`). `nix flake metadata --json` reports both
(`revision`, or `dirtyRevision` for a tree with changes), through the libgit2
already inside `nix`. Bundling `git` would mean relocating its helper programs
and templates on macOS for two facts Kix can get without it.

**`sops` and PGP.** `sops` handles age keys and cloud key services itself. For
PGP keys it runs the user's `gpg`, which holds the private keys. Kix does not
bundle `gpg`.

**The cache-key rule.** If a program can change what Kix produces, its exact
version is part of the cache key for that output. Helm qualifies. Nix does not,
because two Nix versions produced identical output in the spike. Programs that
only talk to a cluster, such as `kubectl`, produce no cached output.

### 3. The store root

Logical store paths stay `/nix/store/<hash>-<name>` everywhere: manifests,
annotations, bundle headers, receipts, and plan documents. Only file reads
change.

`eval::store` gains `store_root()`, `store_dir()`, and `real_path(logical)`.
Every place that reads a store path from disk goes through `real_path`. The
review comment on the issue lists them: the closure loader, `kix-bundle`,
SOPS source resolution, activation lookup by hash, baseline reconstruction,
`kix health`, `kix status`, and `kix diff`. Two of these use
`std::fs::canonicalize` on a symlink into `/nix/store` and must change to
`read_link` plus `real_path`, or they fail on a machine without `/nix`.

`closure_graph` moves onto `nix path-info --json --recursive`, which
`path_info` already parses, and drops the `nix-store -q --graph` parser.

### 4. Evaluate instead of build

`buildCluster` gains `activationIndex`, a file written with `builtins.toFile`:

```nix
activationIndex = builtins.toFile "kix-activation-${name}.json" (builtins.toJSON {
  activation = "${activation}";
  packages = "${packageIndex}";
  scorecard = ...;      # toFile path or null
  extraImages = ...;    # toFile path or null
  imageSources = ...;
  interfaces = { <consumer> = "<path>"; };
});
```

The string context makes Nix record every listed file as a reference, so the
index is a real content-addressed store path with a correct closure. The CLI
runs `nix eval --raw .#legacyPackages.<system>.kixClusters.<name>.activationIndex`
and reads the index instead of a result directory of symlinks. GC roots point
at the index.

`kix.run/built-via` then names the index file instead of a directory. Kix must
read the old directory form for one minor release, because `kix diff`,
`kix status`, `kix rollback`, and baselines read `built-via` from cluster state
written by the previous release.

`mkFlake.nix` stops forcing `pkgs` for anything `kixClusters` needs, and
imports `kix/lib` with `lib` from the flake input rather than `pkgs.lib`.

`mkFlake.nix` drops the `cluster-<name>-activation` output. This is a
"Breaking (shows an error)" change: `nix build` reports a missing attribute.
The two docs pages that use it switch to `kix bundle` and
`kix diff --from-bundle`. `kix diff --from <DIR>` keeps reading old result
directories, which users may have saved.

### 5. Helm through Kix

**Rendering.** `helmTemplateDerivation` and `importChartCrds` become one
primitive that returns a placeholder derivation:

```nix
derivation {
  name = "helm-render-${releaseName}.json";
  system = "kix-helm";
  builder = "kix";                # never run
  kixHelmSpec = builtins.toJSON {
    specVersion = 1;
    helm = "4.3.1";               # exact version from the runtime manifest
    chart = "${chart}";
    inherit releaseName namespace includeCrds includeHooks kubeVersion extraFlags;
    values = <values JSON, context discarded>;
  };
}
```

`importChart` reads it with `builtins.fromJSON (builtins.readFile drv)`.
`importChartCrds` filters the same render to CustomResourceDefinitions in Nix.

The exact Helm version and `specVersion` are in the spec, so a Helm upgrade or
a change to Kix's YAML conversion gives a new output path, and no old render is
reused.

**Where the exact version comes from.** The output path is computed during
evaluation, so `kix/lib` must know the exact Helm version before any Helm runs.
Pure mode blocks the usual ways a running program passes a value in, such as
environment variables and files outside the flake. So the versions live in the
library itself, in `kix/lib/helm-versions.json`:

```json
{ "3": "3.19.1", "4": "4.3.1" }
```

`runtime.nix` reads the same file to fetch the binaries, so one commit of this
repo produces a library and a runtime that agree. When the CLI renders a chart,
it checks that its runtime ships the exact version named in the spec. If it
does not, it stops before rendering:

> This cluster's Kix library renders Helm charts with Helm 4.3.1, but this kix
> binary ships Helm 4.3.2. Update the kix input in flake.lock, or use the kix
> binary of the same version as the library.

This ties the library version in a user's `flake.lock` to the binary version,
but only for clusters that use Helm, and only when a release changed a Helm
version. Kix never renders with a version other than the one the output path
names. To keep the mismatch rare, Helm versions change only in minor releases.

A flake input that the CLI overrides was the other route. It was rejected
because the input would have to be declared in every user's `flake.nix`, under
a name Kix would have to discover.

**The render loop.** When evaluation stops at a missing `kix-helm` output, the
CLI reads the `.drv` from the store, runs the chosen Helm, converts the YAML
stream to a JSON array in Rust, writes the result to the output path, and
registers it with its real NAR hash. Then it evaluates again. Each uncached
chart costs one extra evaluation, and only on the first build after a chart or
its values change. The loop has a fixed iteration cap.

**Fetching.** `fetchHelmChart` becomes a fixed-output placeholder derivation
with the user's `hash`. Nix computes its store path from the hash and name. On
a miss, the CLI pulls the chart with the newest bundled Helm, checks the hash,
and adds the file with `nix-store --add-fixed`, which must produce the same
path. A wrong download cannot land under the expected path. Local chart
directories are copied into the store by Nix as today.

**Choosing a Helm version.** `importChart`, `importChartCrds`, and `helmChart`
take `helmVersion`, which defaults to the newest bundled major:

```nix
scope.helm.importChart { chart = ...; helmVersion = "3"; }
```

A major that the runtime does not ship stops the build with an error that
lists the majors it does ship. When a major is removed from the runtime, a
chart that still asks for it fails the same way, which makes the removal a
"Breaking (shows an error)" change.

**Helm 3 alongside Helm 4.** Helm 3 gets security fixes until
10 February 2027 and nothing after. Pulls always use the newest Helm, so the
older Helm only runs `helm template` on files already on disk. Dropping Helm 3
from the runtime exercises the removal path above.

The `cluster-<name>-activation` output is gone by this phase (section 4), so a
plain `nix build` of a cluster is a missing-attribute error rather than a
failed build.

### 6. Isolation

The bundled Nix always runs in pure mode against a user-owned store under
`$XDG_CACHE_HOME/kix/store`, with the environment from section 2. A CI job runs
`kix build` on a Helm cluster and a non-Helm cluster with `/nix` unreachable: a
mount namespace on Linux, and the spike's `sandbox-exec` profile on macOS.

## Phases

Each phase is one pull request and leaves `main` working.

1. **Runtime lookup and store root.** Add `runtime::tool`, `KIX_RUNTIME_DIR`,
   `KIX_STORE_ROOT`, and `real_path`, and route every call to `nix`,
   `nix-store`, `kubectl`, and `sops`, and every store read, through them.
   Replace the `git` calls with `nix flake metadata`. With neither variable
   set, programs come from `PATH` as today. Tests run a non-Helm cluster
   against a scratch store.
2. **Evaluate instead of build.** Add `activationIndex`, switch the CLI to
   `nix eval`, read both `built-via` forms, update the `built-via` snapshots,
   remove the `cluster-<name>-activation` output, and update the two docs
   pages. Non-Helm clusters build with no `nix build` at all.
3. **Move Helm 3 to Helm 4 under today's mechanism.** A nixpkgs bump renders
   every Helm package and test cluster with Helm 4. Compare the output with
   Helm 3. Any chart whose output changes is listed in the changelog. This
   separates "new Helm" from "new way of running Helm".
4. **Helm through Kix.** The placeholder derivations, the render loop, chart
   fetching, `helmVersion`, Helm 3 and Helm 4 side by side, and removal of
   `pkgs` from `helm.nix`. Exit check: every Helm cluster gives the same
   activation hash as phase 3. This catches differences between `yq` and the
   Rust YAML conversion.
5. **The runtime archive.** `runtime.nix`, the generalised bundle script,
   `manifest.json` and the startup check, macOS targets in the release
   workflow, and a `kix doctor` check.
6. **Bundled by default.** Kix uses its runtime and its own store on every
   machine, with or without Nix installed, and no longer looks on `PATH`. Add
   the `/nix`-blocked CI job. Update the install docs, `cli/README.md`, and the
   changelog.

## Open questions

1. **Which `kubectl` version?** Kubernetes supports `kubectl` within one minor
   version of the cluster. Kix uses it only for `kix logs` and `kix pf`, which
   rarely break across versions. Ship the newest stable release, and revisit
   if a user reports a skew problem.

## Out of scope

- **Air-gapped evaluation.** The first build still downloads the flake inputs
  (mostly nixpkgs source, for `lib`) and every Helm chart. Shipping a copy of
  nixpkgs `lib` and saving charts for transfer are separate issues.
- **Vulnerability scanning.** ROADMAP keeps scanners outside Kix.
- **x86_64-darwin.** Nixpkgs 26.11 no longer supports it.
- **Using the machine's own Nix.** A later advanced option.

## Alternatives considered

- **Download the runtime on first run.** Rejected: it does not work
  air-gapped.
- **Embed the runtime in the `kix` binary.** Rejected for now: a larger binary,
  an unpack step, a writable cache folder, and separate signing on macOS for
  unpacked libraries.
- **Use the `helm` on `PATH`.** Rejected: renders would depend on the machine.
- **Read Helm renders from `~/.cache/kix/helm/` with `builtins.readFile`.**
  Rejected: pure mode refuses absolute paths outside the store.
- **Register a synthesized result directory with a zero hash** (the plan in
  the issue thread). Rejected: the path is not the hash of its contents,
  `nix copy` and `nix store verify` fail, and `built-via` would point at it.
  `activationIndex` gives a real path.
- **One Helm major at a time.** Rejected: supporting two from the start proves
  the runtime can carry several versions, and charts may need the older major
  during a transition.
