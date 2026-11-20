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
  (`.github/workflows/pages.yml`), with its signature
  `kix.run/releases/index.json.sig` and the per-release files beside it:
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
  "expires": "2026-11-15T12:00:00Z",
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
  ],
  "withdrawn": [
    { "version": "0.8.3", "reason": "it deletes Secrets on rollback", "use": "0.8.4" }
  ]
}
```

Archive names stay as they are (`kix-<system>.tar.gz`), so an archive URL is
`<download><name>`. Readers skip fields they do not know. `expires` and
`withdrawn` came with the signed index (§3, §12). A Kix made before then
reads the index without its signature and ignores both fields. A withdrawn
release is not under `releases`, so that Kix does not install it either.

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

**The index is signed too, with a key of its own.** The index decides which
release Kix installs when several match, what `kix upgrade` and `kix self
update` offer, and what the install script fetches. Unsigned, whoever controls
kix.run or the path to it could hide a release, such as one that fixes a
security problem, or serve an old index, and Kix would install an older
signed release without a word. So `pages.yml` signs the index with
`scripts/sign-index.sh` and serves `index.json.sig` beside it, in the same
format as `SHA256SUMS.sig` but with the first line `kix-index-signature v1`.
Kix (`cli/kix/src/release/trust.rs`) and the install script check it. The
signature is a separate file so that `index.json` stays readable by every Kix
already shipped.

The index key (`cli/kix/index-keys/`, secret `KIX_INDEX_SIGNING_KEY`) is not
the release key. Freshness (below) means the site build signs the index every
day, so its key is always online in a workflow that also builds the docs. A
stolen index key lets the thief hide or withdraw a release, which is what an
unsigned index allowed anyway, but not make a release Kix installs. Signing
the index with the release key would have put the key that makes releases
into that workflow. `sign-index.sh` refuses a release key.

**Freshness.** A signature alone does not stop an old signed index being
served again. The index carries `expires`, seven days after `generated`, and
Kix refuses an expired index. `pages.yml` runs daily, so an index is at most
a day old and a failed build has six days of slack. Kix also keeps the newest
index it accepted in `<data dir>/release-index.json` and refuses one older
than that, the timestamp rule of The Update Framework. It also refuses an
index dated more than a day in the future, or one that stays current for
more than eight days, so a stolen key or a wrong clock cannot leave a kept
index that blocks every real one. The install script checks the signature
and `expires`, and keeps nothing.

Freshness matters when Kix chooses a release: the newest patch of a minor,
`kix upgrade`, and `kix self update`. A version named exactly, as `flake.lock`
names it, needs the index only to find its files, and the signed `SHA256SUMS`
protects those. So an exact install with a stale index warns and goes on, and
a pinned project keeps working when the site has not signed for a week.
Only the tip of `main` signs: `pages.yml` refuses to sign in a re-run of an
old run, and a preview from a branch gets an unsigned index. The Worker sends the
index and its signature with `cache-control: no-cache`, so a cache never
pairs one build's index with another build's signature.

A signature file may hold one `keyid` and `signature` pair per key, and a
reader accepts it when one pair verifies. During a rotation the site signs
the index with both keys, so a Kix that knows only the old one keeps working.

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

From 0.10, a project names its Kix by the release tag `v<version>` of its
flake input named `kix`, which `flake.lock` records
(`cli/kix-core/src/flake_lock.rs`, `changes/0.10.0/version-from-flake-lock.md`
once released). The tag is an exact version, so a project's Kix and its Kix
library always have the same version. `kix.toml` names no version and refuses
a `kix` key. A `kix` input on a local folder or a branch is a development
library, and Kix runs the version the user started. Until 0.10, `kix.toml`
named the version with a `kix` key, which this section first described and
the table below still shows.

Selection runs in `main()` before clap parses, because the Kix that should run
may have different flags. It reads `--flake` (or `KIX_FLAKE`) from the raw
arguments, reads only the `kix` input of `flake.lock` (everything else is
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

### 12. A release can be withdrawn

`web/releases/withdrawn.json` lists releases that no one should run, each
with a reason and the release to use instead. The index generator moves them
from `releases` to `withdrawn`, so the signed index (§3) carries the
withdrawal. Kix, `kix upgrade`, `kix self update`, and the install script never pick a
withdrawn release, and `use` must name a newer one. The entry keeps the
release's files, so a project that names the version exactly still installs
it, with a warning. That matters because `kix upgrade` builds with the
project's current Kix before it moves, so a project could not leave a
withdrawn release it cannot install. A withdrawn Kix that is already installed still runs: `kix deploy`
and `kix rollback` refuse to change a cluster with it, and other commands warn.
Deploy and rollback read the kept index and fetch a new one when it is more
than a day old, giving up after a few seconds and falling back to the kept
copy, so a machine that cannot reach kix.run still deploys. The check is
best effort and fails open: a machine that has never fetched the index, and
cannot reach kix.run, deploys without it. Setting
`KIX_ALLOW_WITHDRAWN` to the withdrawn version lets the write through, and the
Activation record then carries `kix.run/withdrawn-kix`. The release skill has
the steps for withdrawing a release.

Not built: the operator does not learn that its own Kix was withdrawn, because
it has no route to kix.run. `housekeeping/2026-11-20-operator-cannot-see-a-withdrawn-kix.md`
lists the options.

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

- **Where `self update` leaves a Nix install.** It prints `nix profile upgrade
  kix` today; a profile installed from a flake reference may need
  `nix profile upgrade <index>`. Check against the Determinate installer.
- **`setup-kix` GitHub Action.** A separate repository that runs the install
  script with a pinned version. Follow-up.
- **Pre-release versions.** The policy ignores a `-rc` suffix. Decide whether
  a project may require one before the first release that has one.
- **The 1.0 cutoff.** How many minors back a 1.x Kix builds, and whether
  `specVersion` or `kixLibrary.version` is the key it reads.
