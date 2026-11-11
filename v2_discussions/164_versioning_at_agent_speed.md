# 164: Versioning at agent speed

**Status:** Accepted (§1 to §4). §5 is a sketch to argue with.
**Related:** `163_cli_install_versions_and_upgrades.md` (selection, signing, the first `kix upgrade`), `140_catalogue_versions_and_upgrade_windows.md` (per-client revisions in the Lithus monorepo), `155_platform_versions_and_compatibility.md`, `164a_versioning_review_record.md` (the eleven reviews behind this doc)

## Context

Kix released five minor versions in seven days (0.5.0 on 4 November 2026 to
0.9.0 on 10 November). The maintainer works with AI coding agents and expects
that pace to continue while the design is young. Most breaking changes are
package or library changes that stop the build with an error that names the
fix. Of the eleven breaking entries in 0.9.0, ten showed an error and one did
not, and none touched the program.

The question was whether the version scheme still serves users at this pace,
and whether the program should be split from the library and packages. Eleven
reviews looked at it: two general reviews, five reviews from different schools
(stability-first, release channels, migrations as code, continuous delivery,
red team), and six from different kinds of user (a homelab user without
agents, a regulated platform team, an agency with many client clusters, an
outside package author, the maintainer, and an unattended upgrade agent). Their
findings and sources are in `164a`.

They agreed on more than expected. The number cannot tell a user "does this
release affect me", so a tool has to, and Kix can answer that exactly because
it knows which packages a project uses and renders deterministic manifests.

## 1. Decisions

### 1.1 Numbering stays `0.N.P`

- Any breaking change raises the minor. A patch never breaks anything.
- Minor releases will come quickly, several a week at times. That is accepted.
- The program and the library keep one shared version, and Kix builds only a
  library of its own minor (`cli/kix-core/src/version/policy.rs`).

Date-based versions lose the signal "this upgrade may need edits". A plain
sequence number leaves users without agents nothing to read. Per-package
versions move the matching work onto users, as Terraform's provider split did.

### 1.2 No compatibility shims, except for cluster state

Package options, library functions, and CLI flags are removed or renamed
without a deprecation period. The release that removes one refuses the old form
with an error that names the new one, and that refusal stays for at least one
minor. `kix upgrade` steps through each minor when a jump fails (§2.5), so a
user always meets the release whose error explains the change.

Cluster state is the exception, because it outlives the Kix that wrote it.
Cluster state means Activation records, `kix.run/*` annotations,
PackageInstance records, and Kix's own custom resources.

**A Kix release reads the cluster state written by any release from the last
six months, or by the previous minor, whichever covers more.** This replaces
"reads the state the previous minor wrote" in `CLAUDE.md`, which at today's
pace is about a day and a half. A change that cannot keep that promise is
marked as a required stop (`required-stop = true` on its record, §2.4). Required stops should be rare.

The window runs forwards only: a newer Kix reads what an older one wrote.
Nothing yet stops an older Kix from deploying onto a cluster that a newer
minor deployed last. 163 §9 designs that refusal, and it is not built. Going
back to an older Kix is also how a user gets away from a bad release, so the
refusal needs an override when it is built (§4, question 6).

### 1.3 No supported line with backports, for now

A security fix ships in the newest minor only. Every security change record
says how to get the fix without upgrading, usually an image pin
(`how-to/promote-images/pin-an-instance-image-without-code`).

Revisit when the design stabilises, or when a regulated or agency user needs
fixes during a change freeze. The regulated-team and agency reviews in `164a`
show what that line would need: a baseline marked in `releases/index.json`
every four to six weeks, with security-only patches.

### 1.4 One repository

The program, library, and packages stay in one repository with one version.
Since 10 October, 60 commits touched both the library and packages, 27 touched
the program and the Nix code together, and 7 touched all three. A split would
turn each into coordinated pull requests and a pin bump.

If a split ever happens, the line runs between the program and the library
plus packages, as nixpkgs keeps `lib` beside the packages. Contracts and the
packages that use them change together.

A Kix that builds older libraries stays deferred to 1.0, as 163 §4 already
says.

Revisit when either of these happens:

1. The interface between the program and the library stops changing often.
   Then build "a newer Kix builds older libraries", which gives most of a
   split's benefit inside one repository.
2. Outside package catalogues exist. Then package sets need declared Kix
   version ranges (`164a`, package author review).

## 2. Tooling, in build order

All of it can be built by agents. The maintainer's judgement is needed in one
place only (§2.2).

### 2.1 Change records

- One file per change, `changes/<name>.md`, so parallel branches never edit
  the same file. `<name>` is free, usually the branch.
- At release the records move to `changes/<version>/` and are kept.
  `CHANGELOG.md` is generated from them.
- A TOML header between `+++` lines, so Python (`tomllib`) and Rust (`toml`)
  read it with no new dependency. Closed fields: an unknown field is an
  error. The prose below the header is for people and becomes one
  CHANGELOG bullet.

```markdown
+++
kind = "error"
packages = ["echo-server", "dns-exporter"]
id = "K0142"
+++
`echo-server` and `dns-exporter` rename `replicaCount` to `replicas`.
```

- `kind` follows the CHANGELOG headings: `error`, `silent`, `note`,
  `security`, `added`, `changed`, `fixed`. Any `error` or `silent` record
  makes the release a minor.
- What a change touches is in separate fields: `packages`, `library`
  (symbols such as `kix.contracts.redis`), `cli` (removed or changed flags
  and commands), `state` (cluster state), `touches-data` (only for
  `silent`), and `required-stop` (only with `state`, §2.4).
- `id` (`K` and four digits) is required for `error` and optional
  otherwise. Security records carry `cve` and a required `workaround`.
- Each release ships its records as `kix-<version>-changes.json`, a release
  asset listed in `SHA256SUMS`, so the signature covers it and nothing new
  is signed.

`changes/README.md` has the full format, and `scripts/change-records.py`
validates it. The Changelog workflow runs the validation on every pull
request.

### 2.2 A pull-request check that works out the kind

The check renders the fixture projects (the test clusters, homelab-kind, and
kix-examples) at the base and the head of each pull request.

- An old definition that fails at head is an `error` change. The check also
  confirms that the message names the replacement.
- Manifests that differ for an unchanged definition need a kind: `fixed`
  or `silent`. **Only the maintainer sets `silent`.** This is the one call an
  agent cannot make reliably.
- A diff of `kix --help` and the JSON schemas catches changes that need the
  `cli` field.
- A test that reads saved cluster state from six months back catches changes
  that need `state = true`.

Running this on the pull request means the agent that caused a diff is still
there to explain it. Part of it exists already: `cli-tests.yml` renders whole
clusters in snapshot tests.

### 2.3 Stable identifiers in refusals

A refusal that a change record describes prints the record's id
(`[K0142]`), and `kix explain K0142` prints the record. Tools and agents match
the id, so the Argon copy pass can reword the sentence freely.

### 2.4 Required stops

A change record with `state = true` can set `required-stop = true`: "deploy
with this release before upgrading further". The flag lives on the record,
so the release index needs no new field. `kix upgrade` stops at that
release.

### 2.5 `kix upgrade`

This extends 163 §8.

1. `--preview` lists, from the change records alone, every record between the
   project's version and the target that touches what the project uses. It
   groups them as edits, silent changes, CLI changes, and state, and says how
   many steps and how much disk the upgrade needs.
2. With no `--to`, the target is the newest release. A delay is opt-in:
   `--min-age 7d`, or `[upgrade] min-age = "7d"` in `kix.toml`.
3. It jumps straight to the target and checks every cluster. If that fails, it
   steps through the newest patch of each minor in between, and stops at the
   first step that fails. It prints the errors and
   that release's change records for the packages in use.
4. It deletes each installed Kix it only passed through. Each one takes about
   290 MB.
5. It searches the project's scripts and CI files for flags named in `cli`
   records.
6. It writes exact pins to `kix.toml` and `flake.lock`, and saves its progress
   in `kix-upgrade.json`, so a person or an agent with no memory can resume.
7. It reports per cluster, and groups identical changes across clusters.
8. Exit codes: 0 done, 2 fixes needed, 3 needs a person. It returns 3 for
   any change no record explains, any `silent` record, any required stop,
   and any diff that touches Secrets, RBAC, NetworkPolicy, or TLS settings.
9. `kix deploy` refuses until the user acknowledges each `silent` record
   marked `touches-data`.

Measured on homelab-kind (328 objects, several Helm charts), starting from an
empty cache: the first check took 10.5 s, mostly rendering Helm charts. The
next version took 1.3 s, because Helm renders are filed by content in Kix's
local store and shared between Kix versions.

### 2.6 Smaller items

- A release mirror setting for CI without internet access.
  `KIX_RELEASE_SOURCE` is test-only today.
- An upgrade how-to page under `docs/src/content/docs/how-to/`.
- `CLAUDE.md` § Versioning and the release skill updated to §1.

## 3. Later, when the need is real

- Per-cluster Kix versions in one project (§5). The Lithus monorepo needs
  this first.
- A security-only backport line (§1.3).
- Declared Kix version ranges for outside package sets.
- Withdrawing a release. Until then, a bad release is fixed by the next
  patch.
- An upgrade bot that opens a pull request for each release that affects a
  project, and merges only when no record applies and nothing changes.

## 4. Open questions

1. **Signing-key rotation breaks stepping.** 163 §3 drops an old key one minor
   after rotation. A newer Kix then cannot verify an older release it needs to
   step through. Keep every past public key in the binary, or sign the index of
   past releases with the current key.
2. **How long a refusal lives.** "At least one minor" is the floor, and §2.5
   relies on it. Should refusals for CLI flags live longer, since a script in a
   notes file is never checked?
3. **Versioned docs.** The docs site appears to serve one version. A user on
   an older Kix copies newer examples. Not checked thoroughly.
4. **Does `kix check` emit evaluation failures as JSON?** The agent review
   found only scorecard JSON and SARIF.
5. **Is six months right?** It is provisional. Measure how often state
   changes before tightening or relaxing it.
6. **Should an older Kix be refused on a cluster a newer minor deployed?**
   163 §9 says yes. With no way to withdraw a release, a user leaves a bad
   release by deploying with the previous Kix, which that refusal would
   block. If it is built, it needs an explicit override.

## 5. Sketch: per-cluster Kix versions

Not for implementation yet. 140 designs per-client revisions for the Lithus
monorepo, before Kix had releases. Now a revision is a Kix release (the
library and the program share a version), so 140's mechanism carries over,
with one new piece: choosing the program per cluster.

### 5.1 What stops it today

- One `kix.toml` per flake names one Kix
  (`cli/kix-cli/src/select.rs`).
- Selection runs before argument parsing and reads only `--flake` and
  `kix.toml` (163 §5). It does not know which cluster a command is for.
- The Lithus monorepo builds every cluster through one `kixpkgs.lib.mkFlake`
  call (`monorepo/src/kix/clusters.nix:93`) from one `kixpkgs` input.
- Shared modules already receive `kix` as an argument
  (`monorepo/src/kix/clusters.nix:45-60`), so they can be built against more
  than one library.

### 5.2 The shape

A project declares its live versions, at most two or three, and each cluster
names one:

```toml
# kix.toml
kix = "0.14"              # the default for clusters that name none

[clusters]
acme-prod = "0.12"        # held back until its next window
```

```nix
# flake.nix: one input per live minor, as the monorepo already does for RKE2
inputs.kixpkgs.url      = "github:kix-run/kix/v0.14.2";
inputs.kixpkgs-0_12.url = "github:kix-run/kix/v0.12.3";
```

```nix
# the library is chosen per cluster
kixpkgs.lib.mkProject {
  libraries = {
    "0.14" = kixpkgs;
    "0.12" = kixpkgs-0_12;
  };
  clusters.acme-prod.file = ./client/acme/clusters/acme-prod/kix/cluster.nix;
}
```

Selection changes in one way. The Kix the user runs parses the command, finds
the cluster, reads that cluster's version from `kix.toml`, and hands over to
the matching Kix with the same arguments and `KIX_SELECTED_BY`, as 163 §5
does now. Commands that cover many clusters, such as `kix list clusters`, run
in the newest Kix and show each cluster's version.

### 5.3 Rules

- A version is a whole release. The library and packages are never mixed
  across versions (140 §2.2 measured why).
- Shared modules and private packages must build against every live version.
  CI builds every cluster with its own library. Modules can read
  `kix.version` to branch, and those branches are the project's to delete.
- `kix upgrade --cluster acme-prod` moves one cluster to another live version.
  Adding a live version adds an input.
- A version past the six-month state window cannot stay live. Expiry, as in
  140 §5.3, keeps the number of live versions small.
- Bumping an input that a cluster does not use changes nothing for that
  cluster. A platform upgrade reaches a client only through a pull request
  against that client's line (140 §5.4).

### 5.4 Until then

One flake per version line, each with its own `kix.toml` and `flake.lock`,
importing the shared modules by relative path and run with `--flake`. This has
not been tried.

### 5.5 Open questions for the sketch

- Is the per-cluster table in `kix.toml`, or in each cluster file, as 140
  §5.2 proposes? `kix.toml` is readable without evaluating anything, which
  selection needs.
- What does evaluating with two library inputs cost? 140 §7 asks the same.
- How does a security fix reach every line without a backport line? Each line
  takes its own upgrade, so the agency carries the cost of old lines.
