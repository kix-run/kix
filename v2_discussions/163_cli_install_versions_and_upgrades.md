# 163: Installing, selecting, and upgrading Kix

**Status:** Accepted
**Related:** `archive/161_rootless_evaluation_bundled_runtime.md` (the release archive and its runtime), `140_catalogue_versions_and_upgrade_windows.md` (§2.4, the partial-apply case this closes), `155_platform_versions_and_compatibility.md` (version checks against the cluster)

## Context

Kix is one binary plus a runtime directory, released as an archive per
platform (`cli/README.md` § Releases). The library a project pins in
`flake.lock` carries the same version number (`kix/lib/default.nix` reads it
from `cli/Cargo.toml`, and `mkFlake.nix` publishes it as
`legacyPackages.<system>.kixLibrary.version`). Today nothing compares the two
except two side effects: a library too old to write an activation index
(`NoActivationIndex`, `cli/kix-core/src/eval/error.rs`) and a Helm version the
running Kix does not ship (`HelmMismatch`, `cli/kix-core/src/library.rs`). A Kix
0.7 builds a 0.8 library without a word when no chart is involved
(`housekeeping/2026-11-08-cli-library-version-check-needs-a-helm-chart.md`).

Installing is a manual `curl | tar` from GitHub, and `web/install.sh` still
installs through a Nix profile, which the runtime work in 161 made obsolete.
Two people on one project, or a laptop and CI, have no way to agree on a Kix
version other than reading the changelog.

This document records the decisions for installing Kix, keeping it in step
with a project's library, and moving a project to a newer Kix. The decisions
were taken with the maintainer and are not reopened here. What remains open
is listed at the end.

## Decisions

### 1. One install path: `curl -fsSL https://kix.run/install | sh`

The script downloads the release archive for the machine's platform, checks
its SHA-256 against the signed `SHA256SUMS`, unpacks it to
`~/.local/share/kix/<version>/` (the archive already unpacks to
`kix-<version>-<system>/`, which the script renames), points the symlink
`~/.local/bin/kix` at the newest installed version, and writes a receipt
(`~/.local/share/kix/receipt.json`, `{"installer": "script", "version": ...}`).
It never edits a shell rc file. When `~/.local/bin` is not on `PATH`, it
prints the line to add. `KIX_VERSION=0.8.3` installs a specific version. It
takes an exact version only, and the receipt also records the `link` the
script made, which `kix self update` moves.

Rejected: Homebrew, apt, and rpm (each is a second release pipeline with its
own version lag, and the auto-install in §5 covers the main reason people want
a package manager, which is getting the right version). A Nix profile install
stays possible for people who have Nix, and `kix self update` tells them to
use `nix profile upgrade` (§6).

### 2. Everything the installed Kix talks to is on kix.run

The binary and the install script fetch from `kix.run` only. Where the
archives are stored (today, GitHub releases in `kix-run/kix-releases`) is a
detail of the site build and the site Worker, and moving them changes no
shipped binary.

- `kix.run/releases/index.json` lists the releases that have a signed
  `SHA256SUMS`. It is a static asset that the site build writes
  (`.github/workflows/pages.yml`), with the per-release files beside it:
  `kix.run/releases/v<version>/SHA256SUMS` and `SHA256SUMS.sig`.
- `kix.run/download/<version>/<file>` serves an archive. The site Worker
  (`web/public/_worker.js`) answers with a redirect to wherever the file is
  stored. Clients follow the redirect and verify what they get, so the storage
  location carries no trust.
- `kix.run/install` is the script, served from `web/public/install`.

The site build is what couples these to the current storage host. A step in
`pages.yml` reads the `v*` tags of this repository, fetches each release's
`SHA256SUMS` and `SHA256SUMS.sig` from the host, keeps the releases that have
both, and runs the index generator (`web/scripts/release-index.mjs`) over
them. A release that is tagged but not yet published, or published without a
signature, is left out, and the next site build picks it up. The release job
starts a site build after it tags, and `pages.yml` runs under one concurrency
group, so the index is at most one build behind.

The index shape:

```json
{
  "schema": "kix.run/releases/v1",
  "generated": "2026-11-08T12:00:00Z",
  "latest": "0.8.4",
  "releases": [
    {
      "version": "0.8.4",
      "date": "2026-11-07",
      "systems": ["x86_64-linux", "aarch64-linux", "aarch64-darwin"],
      "sums": "/releases/v0.8.4/SHA256SUMS",
      "signature": "/releases/v0.8.4/SHA256SUMS.sig",
      "download": "/download/0.8.4/"
    }
  ]
}
```

Archive names stay as they are (`kix-<system>.tar.gz`), so an archive URL is
`<download><name>`. Readers skip fields they do not know.

Rejected: reading the index from the GitHub API or a GitHub release asset
(binds every shipped binary to GitHub). Rejected: committing release metadata
to this repository from the publish job (CI pushing to a protected `main`).

### 3. Signed releases, with one key in the binary

The `publish` job signs `SHA256SUMS` with Ed25519 and uploads the signature
beside it. The signature file is text:

```
kix-release-signature v1
keyid=3f9a1c2e
signature=<base64 of the 64-byte Ed25519 signature over the bytes of SHA256SUMS>
```

The public key lives in the repository as `cli/release-keys/<keyid>.pub` (raw
32 bytes, hex) and is compiled into Kix with `include_str!`. Kix verifies with
`ring::signature::ED25519`, which the binary already links through rustls, so
no new crate is needed. Signing in CI uses OpenSSL (`openssl pkeyutl -sign
-rawin`), with the private key in the repository secret
`KIX_RELEASE_SIGNING_KEY`.

Rotation: a new key is added as a second `.pub` file and compiled into a
release signed by the old key; from then on releases are signed by the new
key; the old key is dropped one minor release later. `keyid` in the signature
file selects the key, so a Kix that knows both verifies either.

The install script carries the same public key and verifies the signature when
the machine's `openssl` can (OpenSSL 3 can; older LibreSSL cannot); when it
cannot, it says so and relies on the SHA-256 and TLS. Every later install goes
through Kix itself, which always verifies. The script's copy of the key is
checked against the repository file by a test.

Rejected: minisign and signify (a second tool in CI and a format Kix would
have to parse; the raw signature is enough for one producer and one consumer).
Rejected: Sigstore (a network dependency on a third party at verify time).

### 4. Compatibility rule, in one module

Before 1.0: Kix and the library must have the same minor, and Kix's patch must
be greater than or equal to the library's. A patch release may add a Helm
version and never removes one; only a minor release removes. The rule lives in
`cli/kix-core/src/version/policy.rs` and nothing else compares versions, so the
move at 1.0 to "a newer Kix builds older libraries back to a cutoff" changes
that module and the `specVersion` the library writes into chart fetch specs
(`kix/lib/helm.nix`, `fetchSpec`), which is the hook for a future Kix to read
older library output.

### 5. A project names its Kix, and Kix selects itself

`kix.toml` gains `kix = "0.8"` (a minor) or `kix = "0.8.3"` (exact). Kix 0.7
already refuses an unknown key and says to upgrade (`project.rs`,
`UnknownKey`), which is the right outcome for a 0.7 that meets a 0.8 project.
For the same reason a project cannot name Kix 0.7 or older: no such Kix could
read the file, so `kix = "0.7"` is a `kix.toml` error (`FIRST_SELECTING` in
`policy.rs`). The library ignores keys it does not read (`mkFlake.nix` reads
`settings.builder or "kix"`), so the key costs nothing there.

Selection runs in `main()` before clap parses, because the Kix that should run
may have different flags. It reads `--flake` (or `KIX_FLAKE`) from the raw
arguments, reads only the `kix` key of `kix.toml` (other keys and errors are
left to the Kix that runs, so an older Kix can hand over to a newer one), and
decides:

| Situation | Action |
|---|---|
| No `kix.toml`, or no `kix` key | Run here |
| The running Kix satisfies the requirement, and no newer installed Kix does | Run here |
| An installed Kix satisfies it and is newer than the running one (newest patch of the minor wins) | `exec` it |
| None installed, auto-install on | Install the newest patch of the minor, then `exec` it |
| None installed, `KIX_AUTO_INSTALL=0` | Stop: `This project needs Kix 0.8 (kix.toml), and no Kix 0.8 is installed. Automatic installs are off (KIX_AUTO_INSTALL=0). Run \`kix self install 0.8\`.` |

`self`, `completions`, `init`, `help`, and `--help` skip selection.
`--version` goes through it, so what it prints is what the project runs, but
it never installs: without an installed match it prints the running version
and says the project's version is not installed. Selection reads
`kix.toml` and lists the install directory, runs no Nix, and makes no
network request unless it has to install. A newer installed patch of the
minor replaces the running one, so a library that needs that patch is fixed
with `kix self install 0.8`.

The hand-over contract between any two Kix versions is permanent: the chooser
`exec`s `<install>/bin/kix` with its own arguments unchanged, plus the
environment variable `KIX_SELECTED_BY=<path of the chooser>`. A Kix that finds
the variable set never selects again, which ends any loop; `kix --version` and
`kix doctor` print who chose it. Windows has no `exec` and Kix does not
support Windows.

Rejected: a separate launcher binary (a second thing to install and version;
every Kix is already a capable launcher). Rejected: a per-tool version cache
such as `~/.cache/kix/tools` (Kix downloads Kix and nothing else, see §6).

### 6. Kix downloads Kix

Auto-install is on by default and prints one line:
`Installing Kix 0.8.4 (this project needs 0.8)`. It fetches the index, picks
the newest patch of the required minor for this platform, downloads the
archive through `kix.run/download/`, checks the SHA-256 against the signed
`SHA256SUMS`, verifies the signature, and unpacks under
`~/.local/share/kix/<version>/`. A release without a signature, or whose
signature does not verify, is refused with the reason. `KIX_AUTO_INSTALL=0`
turns the download off.

This amends 161's "Kix never downloads a program": Kix may download Kix. It
still never downloads the programs it runs; those arrive inside the signed
archive.

`kix self install <version>`, `kix self list`, and `kix self prune` manage the
installed versions. `kix self update` installs the newest release for this
platform and moves the link the receipt names when the receipt says the script
installed this copy. Otherwise it prints the command for the way Kix was
installed (for a Nix profile, `nix profile upgrade kix`) and exits 1. A daily notice says when a newer Kix exists, and a
separate one says when the project's minor can move; both are off when `CI` is
set or `KIX_NO_UPDATE_CHECK=1`.

### 7. The library check rides the existing evaluation

After evaluation, Kix compares `kixLibrary.version` with its own version
through the policy module. The comparison is folded into the once-per-run
builder agreement check (`check_library_builder` in `cli/kix-core/src/eval/nix.rs`,
`check_agreement` in `project.rs`), which already evaluates
`legacyPackages.<system>`; one `--apply` reads both values, so the check costs
no extra Nix call. `HelmMismatch` stays as a backstop for a library whose
version the check cannot read.

### 8. `kix upgrade`

In a project, `kix upgrade` installs the newest minor, rewrites the
`github:kix-run/kixpkgs/vX.Y.Z` tag form in `flake.nix` (today `kix lib
update` gives up on a tag pin, `classify` in `library.rs`), moves `flake.lock`
with the `kix lib update` code, sets `kix` in `kix.toml`, and prints that
minor's "Before you upgrade" list, which is compiled into the binary from
`CHANGELOG.md` so no network is needed to read it. The user then runs
`kix diff` and commits.

### 9. The cluster remembers which Kix deployed it

An Activation record carries the Kix version and the commit of the deploy that
wrote it, as the annotations `kix.run/deployed-by` and `kix.run/deployed-from`
(`finalize_deploy` already patches the record's annotations; the commit is
the receipt's `source.gitCommit`). The planner reads them off the Active
record it already loads as its baseline. `kix plan` and `kix diff` warn when
the record's minor is newer than the running Kix; `kix deploy` refuses:
`prod was last deployed by Kix 0.9 (from commit abc1234), and this Kix is
0.8.4. Make the change on a commit that uses Kix 0.9, or deploy with Kix 0.9`.
The operator runs the same check. This is a refusal in the same family as the
Kubernetes version check (`kubernetes_version::check`): it never changes what
is applied, so the rule that a deploy never decides from live state holds.

### 10. The plan document names the baseline's Kix

The plan document gains the baseline's Kix version beside the record change,
so the renderer prints "This deploy moves prod from Kix 0.8 to 0.9" and that
minor's upgrade notes.

### 11. One version type

`kix::VERSION` (with `+build` metadata) and `library::PROGRAM_VERSION` (the
crate version) become one `kix::version::Version` with the running version
parsed once. Messages that name a release use `release()` (no build
metadata); the plan document and receipts keep the full string. `kix
--version` prints `kix <version>` first, as the release job checks, and adds
the `PATH` version and the chooser only when they differ from the running one.

## Alternatives considered

- **Never download, print instructions instead.** Keeps 161's rule intact.
  Rejected because the person who hits a version mismatch is most often a
  teammate or a CI job with no context, and a one-line install that verifies a
  signature is safer than a copied `curl | tar`.
- **One Kix that builds every library version.** The right end state after
  1.0, and the reason the policy is one module. Before 1.0 the library changes
  shape between minors, so a Kix would carry one evaluator per minor.
- **Versioned install through the package manager of the OS.** See §1.
- **A launcher binary (`kixup`).** See §5.
- **Putting the index in the GitHub release.** See §2.

## Migration

- Projects add `kix = "0.8"` to `kix.toml`; `kix upgrade` does it for them from
  the next minor on. A project without the key keeps working.
- Releases before signing have no `SHA256SUMS.sig`, so they are not in the
  index and cannot be auto-installed. No project needs them: the `kix` key
  starts with the first signed release.
- The manual install in the docs becomes the script; the Nix install stays a
  section for people who have Nix.
- Records written before §9 have no `kix.run/deployed-by`; the check treats a
  missing annotation as "unknown" and says nothing.

## Open questions

- **Signed index.** The index is unsigned; only `SHA256SUMS` is signed. A
  compromised site could hide a release or offer an older signed one. Signing
  the index means the signing key reaches the site build too. Decide when the
  first outside user depends on auto-install.
- **Where `self update` leaves a Nix install.** It prints `nix profile upgrade
  kix` today; a profile installed from a flake reference may need
  `nix profile upgrade <index>`. Check against the Determinate installer.
- **`setup-kix` GitHub Action.** A separate repository that runs the install
  script with a pinned version. Follow-up.
- **Pre-release versions.** The policy ignores a `-rc` suffix. Decide whether
  a project may require one before the first release that has one.
- **The 1.0 cutoff.** How many minors back a 1.x Kix builds, and whether
  `specVersion` or `kixLibrary.version` is the key it reads.
