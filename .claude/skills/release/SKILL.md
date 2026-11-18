---
name: release
description: Cut a Kix release. Picks the next version from the change records in changes/, bumps it, writes the CHANGELOG.md section, opens and merges the release pull request, and confirms CI published the binaries. Use when asked to release Kix, cut a release, or publish a new version.
---

# Releasing Kix

Merging a change to the workspace version in `cli/Cargo.toml` releases Kix.
After the merge, CI builds the binaries, publishes them to
`kix-run/kix-releases` with that version's `CHANGELOG.md` section as the
release notes and its change records as `kix-<version>-changes.json`, and
tags the commit `v<version>`. `cli/README.md` § Releases
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
- Run `scripts/change-records.py check`, then
  `scripts/change-records.py bump`. If `bump` prints `none`, there are no
  unreleased change records and nothing to release. Tell the person and
  stop.
- If signing, the install script, or the release index changed since the
  last release, rehearse first:
  `gh workflow run cli-tests.yml --ref main -f rehearse=0.0.1`, and check
  that the `rehearse-release` job passes. It signs with the real key and
  installs from a local copy of the release site, publishing nothing.

## 1. Pick the version

Each unreleased change is one file directly under `changes/`
(`changes/README.md` has the format). Read every one, and check that its
`kind` is right. `CLAUDE.md` § Versioning and breaking changes says what
counts as breaking. The kind picks the `CHANGELOG.md` heading:

1. `error`, `### Breaking (shows an error)`: Kix stops with an error that
   says what to change, such as a build that fails until a package sets a
   new value.
2. `silent`, `### Breaking (no error)`: nothing fails, but the result is
   different, such as a package that now looks for its files in another
   folder.
3. `note`, `### Upgrade notes`: nothing to change, but worth knowing, such
   as a first deploy that restarts some pods once.
4. `security`, `### Security`: a vulnerability fix. Its `workaround`, when
   there is one, says how to get the fix without upgrading.
5. `added`, `changed`, and `fixed`: `### Added`, `### Changed`, and
   `### Fixed`.

Fix a record whose kind is wrong. Adding a field, event type, annotation,
option, or command is not breaking. Removing or renaming one is. Each
breaking record says what users change when they upgrade. If a `silent`
record could have shown an error with little work, tell the person. Run
`scripts/change-records.py check` again after any edit.

Then read `version` under `[workspace.package]` in `cli/Cargo.toml`, and run
`scripts/change-records.py bump`. Kix is below 1.0, so:

- If the version is a prerelease, `X.Y.Z-rc.N`, the release is `X.Y.Z`
  (§ Prereleases), whatever `bump` prints.
- If `bump` prints `minor`, raise the minor version and set the patch to 0:
  `0.3.2` becomes `0.4.0`.
- If it prints `patch`, raise the patch version: `0.3.2` becomes `0.3.3`.

Make no other choice: no skipped numbers. If the person names a version, use
it only if it is higher than the current one.

### Prereleases

When the person asks for a prerelease (a release candidate, beta, or "rc"):

- If the current version is a release, pick the next version as above and
  add `-rc.1`: `0.7.1` with breaking entries becomes `0.8.0-rc.1`.
- If the current version is already a prerelease, `X.Y.Z-rc.N`, the next
  prerelease is `X.Y.Z-rc.<N+1>` and the release is `X.Y.Z`. Do not apply
  the rules above again. The unreleased records still include the ones that
  made `X.Y.Z` a minor or patch release, and raising again would skip it.

A prerelease is published like a release, with these differences, all
automatic:

- Its notes are written from the unreleased change records
  (`scripts/change-records.py changelog`), so in step 2 skip step 4: the
  records stay where they are, and `CHANGELOG.md` is left alone. The
  Changelog check fails a pull request that changes `cli/` and adds no
  record, so label the release pull request `no-changelog`.
- kix.run lists it as a prerelease and never as the latest release, and the
  docs site keeps serving the last release's docs.
- Kix installs it only when it is named in full:
  `kix self install 0.8.0-rc.1`, `KIX_VERSION=0.8.0-rc.1` for the install
  script, `kix upgrade --to 0.8.0-rc.1`, or a project whose `flake.lock`
  pins the tag `v0.8.0-rc.1`. `kix self install 0.8` never picks it.

The release that follows the prereleases (`0.8.0`) is cut as usual, from the
same unreleased records, with the version taken from the prerelease.

## 2. Edit the files

1. `cli/Cargo.toml`: set `version` under `[workspace.package]`.
2. The lockfiles: run `cargo update --workspace` in `cli/` and
   `cargo update -p kix-lib -p kix-bundle -p kix-container` in `cli/fuzz/`.
   Check that the diff changes only the `version` lines of Kix's own crates.
3. The docs' captured command output. Package version bumps leave it
   alone, so the release regenerates all of it:
   `nix run ./docs#regen-captures-offline -- --apply`. Run this after step
   1, since some captures show `kix --version` and the Nix store path of
   the `kix` package. Revert a file in which only a timestamp changed.
   Read the rest of the diff: each change should come from a package
   version or a change record of this release. Without this step, the
   Documentation captures check fails on the release pull request.
4. The change records. First read the section they make:
   `scripts/change-records.py changelog`. If a bullet reads wrongly, fix
   the wording in its record. Then run
   `scripts/change-records.py release <version>`. It moves the unreleased
   records into `changes/<version>/` and adds the section
   `## <version> - <YYYY-MM-DD>`, with today's date, to the top of
   `CHANGELOG.md`. Check that the new section is the one you read. For a
   prerelease, skip this step.
5. The cluster state fixtures in `cli/kix/tests/fixtures/cluster-state/`,
   only when a record of this release has `state = true`. Copy the newest
   folder to `<version>/`, set `version` and `date` in its `written.toml`,
   and replace the objects with ones this release writes. Delete
   `expected.json`, run `cargo test -p kix-lib cluster_state` to write a new
   one, and check each value in it.
6. Required stops. When a record in the new section has
   `required-stop = true`, add the version to `REQUIRED_STOPS` in
   `cli/kix/src/cluster/stops.rs`. `kix deploy`, `kix rollback`, and the
   operator then refuse a cluster last deployed by an older Kix when the Kix
   deploying it is newer than that release's minor. Skip this for a prerelease.

## 3. Open and merge the pull request

Commit with the subject `Release <version>`. Open the pull request with the
same title, and the new changelog section as its body.

When every check passes, merge it with a merge commit:
`gh pr merge <number> --merge`.

## 4. Confirm the release

The merge starts the CLI tests workflow on main, and its `runtime`, `build`,
`release`, `without-nix`, and `publish` jobs build, verify, and publish the release.
Follow the run with `gh run watch`. Then check:

- `gh release view v<version> --repo kix-run/kix-releases` lists the three
  platform release archives (`x86_64-linux`, `aarch64-linux`, `aarch64-darwin`),
  `kix-<version>-third-party-sources.tar.zst`,
  `kix-<version>-changes.json`, `SHA256SUMS`, and
  `SHA256SUMS.sig`, and shows the changelog section as the notes.
- `git ls-remote --tags origin v<version>` shows the tag.
- The site rebuild that `publish` starts writes `kix.run/releases/index.json`.
  Once the "Deploy site to Cloudflare Pages" run finishes,
  `curl -s https://kix.run/releases/index.json | grep <version>` shows the
  release, and `curl -fsSL https://kix.run/install | KIX_VERSION=<version> sh`
  installs it. For a prerelease, the index entry has `"prerelease": true` and
  `latest` still names the last release.

If `publish` stops at "Sign checksums", the secret `KIX_RELEASE_SIGNING_KEY`
is missing or its public key is not committed in `cli/kix/release-keys/`. Ask the
person to fix it (`cli/kix/release-keys/README.md`), then run the job again.

While `cli/kix/release-keys/` holds no `*.pub` key, "Sign checksums" passes with a
warning and the release goes out without `SHA256SUMS.sig`. kix.run does not
list an unsigned release, so the index and install-script checks above do not
find it, and Kix cannot install it automatically. Tell the person the release
is unsigned and point them at `cli/kix/release-keys/README.md` to add a key.

Give the person the release URL.

If the job failed, read its log, fix the cause, and run the job again. A
second run is safe: it skips a release that already exists in
`kix-run/kix-releases` and creates the tag last. A later push to main can
replace the run for the merge commit while that run waits to start. The
later run then publishes the release, from the later commit.
