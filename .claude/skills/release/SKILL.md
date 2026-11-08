---
name: release
description: Cut a Kix release. Picks the next version from CHANGELOG.md, bumps it, opens and merges the release pull request, and confirms CI published the binaries. Use when asked to release Kix, cut a release, or publish a new version.
---

# Releasing Kix

Merging a change to the workspace version in `cli/Cargo.toml` releases Kix.
After the merge, CI builds the binaries, publishes them to
`kix-run/kix-releases` with that version's `CHANGELOG.md` section as the
release notes, and tags the commit `v<version>`. `cli/README.md` § Releases
explains how the job decides.

You may merge the release pull request yourself once its checks pass.

## Before you start

- Work in a new worktree from `origin/main`, outside this checkout
  (`CLAUDE.md` § Build caches and disk).
- Check that main is green:
  `gh run list --workflow cli-tests.yml --branch main --limit 1`. If the
  last run failed, tell the person and stop.
- Check that no release pull request is open:
  `gh pr list --search 'Release in:title'`.
- Read `## Unreleased` in `CHANGELOG.md`. If it has no entries, there is
  nothing to release. Tell the person and stop.
- If signing, the install script, or the release index changed since the
  last release, rehearse first:
  `gh workflow run cli-tests.yml --ref main -f rehearse=0.0.1`, and check
  that the `rehearse-release` job passes. It signs with the real key and
  installs from a local copy of the release site, publishing nothing.

## 1. Pick the version

Read every entry under `## Unreleased`, and check that each one is under
the right heading. `CLAUDE.md` § Versioning and breaking changes says what
counts as breaking. Use these headings, in this order, and leave out any
that would be empty:

1. `### Breaking (shows an error)`: Kix stops with an error that says what
   to change, such as a build that fails until a package sets a new value.
2. `### Breaking (no error)`: nothing fails, but the result is different,
   such as a package that now looks for its files in another folder.
3. `### Upgrade notes`: nothing to change, but worth knowing, such as a
   first deploy that restarts some pods once.
4. `### Added`, `### Changed`, and `### Fixed`.

`## Unreleased` may start with a **Before you upgrade** list, above the
first heading. It is not a heading, so it stays where it is and moves with
the release. Check that it has one bullet for each action that a Breaking
entry asks of users, and no others.

Move an entry that is under the wrong heading. Adding a field, event type,
annotation, option, or command is not breaking. Removing or renaming one is.
Each breaking entry says what users change when they upgrade. If an entry
under `### Breaking (no error)` could have shown an error with little work,
tell the person.

Then read `version` under `[workspace.package]` in `cli/Cargo.toml`. Kix is
below 1.0, so:

- If the version is a prerelease, `X.Y.Z-rc.N`, the release is `X.Y.Z`
  (§ Prereleases), whatever `## Unreleased` holds.
- If `## Unreleased` has either `### Breaking` section, raise the minor version
  and set the patch to 0: `0.3.2` becomes `0.4.0`.
- Otherwise raise the patch version: `0.3.2` becomes `0.3.3`.

Make no other choice: no skipped numbers. If the person names a version, use
it only if it is higher than the current one.

### Prereleases

When the person asks for a prerelease (a release candidate, beta, or "rc"):

- If the current version is a release, pick the next version as above and
  add `-rc.1`: `0.7.1` with breaking entries becomes `0.8.0-rc.1`.
- If the current version is already a prerelease, `X.Y.Z-rc.N`, the next
  prerelease is `X.Y.Z-rc.<N+1>` and the release is `X.Y.Z`. Do not apply
  the rules above again. `## Unreleased` still holds the entries that made
  `X.Y.Z` a minor or patch release, and raising again would skip it.

A prerelease is published like a release, with these differences, all
automatic:

- Its notes are `## Unreleased`, so in step 2 leave `CHANGELOG.md` alone.
- kix.run lists it as a prerelease and never as the latest release, and the
  docs site keeps serving the last release's docs.
- Kix installs it only when it is named in full:
  `kix self install 0.8.0-rc.1`, `KIX_VERSION=0.8.0-rc.1` for the install
  script, or `kix = "0.8.0-rc.1"` in `kix.toml`. `kix = "0.8"` never picks it.

The release that follows the prereleases (`0.8.0`) is cut as usual, from the
same `## Unreleased` section, with the version taken from the prerelease.

## 2. Edit the files

1. `cli/Cargo.toml`: set `version` under `[workspace.package]`.
2. The lockfiles: run `cargo update --workspace` in `cli/` and
   `cargo update -p kix-lib -p kix-bundle -p kix-container` in `cli/fuzz/`.
   Check that the diff changes only the `version` lines of Kix's own crates.
3. The docs capture the output of `kix --version`, and some captures show
   the Nix store path of the `kix` package. Replace the old version in each
   sidecar that shows it: `git grep -l -e 'kix <old version>' -e
   'kix-<old version>' docs/src/command-output`. Without this, the Documentation captures check
   fails on the release pull request.
4. `CHANGELOG.md`: rename `## Unreleased` to `## <version> - <YYYY-MM-DD>`
   with today's date, and put a new, empty `## Unreleased` above it. Remove
   empty sections. Leave the wording of the entries alone. For a prerelease,
   skip this step.

## 3. Open and merge the pull request

Commit with the subject `Release <version>`. Open the pull request with the
same title, and the new changelog section as its body.

When every check passes, merge it with a merge commit:
`gh pr merge <number> --merge`.

## 4. Confirm the release

The merge starts the CLI tests workflow on main, and its `runtime`, `release`,
`without-nix`, and `publish` jobs build, verify, and publish the release.
Follow the run with `gh run watch`. Then check:

- `gh release view v<version> --repo kix-run/kix-releases` lists the three
  platform release archives (`x86_64-linux`, `aarch64-linux`, `aarch64-darwin`),
  `kix-<version>-third-party-sources.tar.zst`, `SHA256SUMS`, and
  `SHA256SUMS.sig`, and shows the changelog section as the notes.
- `git ls-remote --tags origin v<version>` shows the tag.
- The site rebuild that `publish` starts writes `kix.run/releases/index.json`.
  Once the "Deploy site to Cloudflare Pages" run finishes,
  `curl -s https://kix.run/releases/index.json | grep <version>` shows the
  release, and `curl -fsSL https://kix.run/install | KIX_VERSION=<version> sh`
  installs it. For a prerelease, the index entry has `"prerelease": true` and
  `latest` still names the last release.

If `publish` stops at "Sign checksums", the secret `KIX_RELEASE_SIGNING_KEY`
is missing or its public key is not committed in `cli/release-keys/`. Ask the
person to fix it (`cli/release-keys/README.md`), then run the job again.

While `cli/release-keys/` holds no `*.pub` key, "Sign checksums" passes with a
warning and the release goes out without `SHA256SUMS.sig`. kix.run does not
list an unsigned release, so the index and install-script checks above do not
find it, and Kix cannot install it automatically. Tell the person the release
is unsigned and point them at `cli/release-keys/README.md` to add a key.

Give the person the release URL.

If the job failed, read its log, fix the cause, and run the job again. A
second run is safe: it skips a release that already exists in
`kix-run/kix-releases` and creates the tag last. A later push to main can
replace the run for the merge commit while that run waits to start. The
later run then publishes the release, from the later commit.
