# 2026-11-21 · `cli/kix-core`, `kix/lib` · An older Kix skips unknown settings without saying so.

In a project with a `[versions]` table, a Kix older than the release `kix`
pins skips the `kix.toml` settings and `mkFlake` arguments it does not know
(`ProjectConfig::parse` in `cli/kix-core/src/project.rs`, `checked` in
`kix/lib/mkFlake.nix`). It prints nothing.

The clusters on the older version are usually production. If a later
release adds a setting that changes what every cluster builds, production
builds without it and nothing on screen says so.

One fix is a warning line that names each skipped setting and the version
of Kix that skipped it. It would print on every command for those clusters
until they upgrade. Another is to let a new setting declare that an older
Kix must refuse it.

Found by a review of kix#288 on 21 November 2026.
