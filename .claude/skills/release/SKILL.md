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

Move an entry that is under the wrong heading. Adding a field, event type,
annotation, option, or command is not breaking. Removing or renaming one is.
Each breaking entry says what users change when they upgrade. If an entry
under `### Breaking (no error)` could have shown an error with little work,
tell the person.

Then read `version` under `[workspace.package]` in `cli/Cargo.toml`. Kix is
below 1.0, so:

- If `## Unreleased` has either `### Breaking` section, raise the minor version
  and set the patch to 0: `0.3.2` becomes `0.4.0`.
- Otherwise raise the patch version: `0.3.2` becomes `0.3.3`.

Make no other choice: no skipped numbers and no pre-release suffixes. If the
person names a version, use it only if it is higher than the current one.

## 2. Edit the files

1. `cli/Cargo.toml`: set `version` under `[workspace.package]`.
2. The lockfiles: run `cargo update --workspace` in `cli/` and
   `cargo update -p kix-lib -p kix-bundle -p kix-container` in `cli/fuzz/`.
   Check that the diff changes only the `version` lines of Kix's own crates.
3. The docs capture the output of `kix --version`. Replace the old version
   in each sidecar that shows it: `git grep -l 'kix <old version>'
   docs/src/command-output`. Without this, the Documentation captures check
   fails on the release pull request.
4. `CHANGELOG.md`: rename `## Unreleased` to `## <version> - <YYYY-MM-DD>`
   with today's date, and put a new, empty `## Unreleased` above it. Remove
   empty sections. Leave the wording of the entries alone.

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
  platform tarballs (`x86_64-linux`, `aarch64-linux`, `aarch64-darwin`),
  `kix-<version>-third-party-sources.tar.zst`, and `SHA256SUMS`, and shows the
  changelog section as the notes.
- `git ls-remote --tags origin v<version>` shows the tag.

Give the person the release URL.

If the job failed, read its log, fix the cause, and run the job again. A
second run is safe: it skips a release that already exists in
`kix-run/kix-releases` and creates the tag last. A later push to main can
replace the run for the merge commit while that run waits to start. The
later run then publishes the release, from the later commit.
