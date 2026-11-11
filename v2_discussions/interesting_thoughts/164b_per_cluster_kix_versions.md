# 164b: Per-cluster Kix versions in one project

**Status:** Exploration
**Related:** `../archive/164_versioning_at_agent_speed.md` (the versioning decisions this came from), `../140_catalogue_versions_and_upgrade_windows.md`

A sketch, lifted from doc 164 when its tooling shipped. Not for implementation
yet. The Lithus monorepo needs this first.

Not for implementation yet. 140 designs per-client revisions for the Lithus
monorepo, before Kix had releases. Now a revision is a Kix release (the
library and the program share a version), so 140's mechanism carries over,
with one new piece: choosing the program per cluster.

## 1. What stops it today

- One `kix.toml` per flake names one Kix
  (`cli/kix-cli/src/select.rs`).
- Selection runs before argument parsing and reads only `--flake` and
  `kix.toml` (163 this doc). It does not know which cluster a command is for.
- The Lithus monorepo builds every cluster through one `kixpkgs.lib.mkFlake`
  call (`monorepo/src/kix/clusters.nix:93`) from one `kixpkgs` input.
- Shared modules already receive `kix` as an argument
  (`monorepo/src/kix/clusters.nix:45-60`), so they can be built against more
  than one library.

## 2. The shape

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
the matching Kix with the same arguments and `KIX_SELECTED_BY`, as 163 this doc
does now. Commands that cover many clusters, such as `kix list clusters`, run
in the newest Kix and show each cluster's version.

## 3. Rules

- A version is a whole release. The library and packages are never mixed
  across versions (140 §2.2 measured why).
- Shared modules and private packages must build against every live version.
  CI builds every cluster with its own library. Modules can read
  `kix.version` to branch, and those branches are the project's to delete.
- `kix upgrade --cluster acme-prod` moves one cluster to another live version.
  Adding a live version adds an input.
- A version past the six-month state window cannot stay live. Expiry, as in
  140 this doc.3, keeps the number of live versions small.
- Bumping an input that a cluster does not use changes nothing for that
  cluster. A platform upgrade reaches a client only through a pull request
  against that client's line (140 this doc.4).

## 4. Until then

One flake per version line, each with its own `kix.toml` and `flake.lock`,
importing the shared modules by relative path and run with `--flake`. This has
not been tried.

## 5. Open questions for the sketch

- Is the per-cluster table in `kix.toml`, or in each cluster file, as 140
  this doc.2 proposes? `kix.toml` is readable without evaluating anything, which
  selection needs.
- What does evaluating with two library inputs cost? 140 §7 asks the same.
- How does a security fix reach every line without a backport line? Each line
  takes its own upgrade, so the agency carries the cost of old lines.

## Other things doc 164 left for later

- A security-only backport line (164 §1.3).
- Declared Kix version ranges for outside package sets.
- Withdrawing a release. Until then, a bad release is fixed by the next patch.
- An upgrade bot that opens a pull request for each release, and merges only
  when nothing in any cluster changes.
