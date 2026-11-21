+++
kind = "added"
+++
In projects with a `[versions]` table in `kix.toml`, `kix upgrade` now accepts an input name or a cluster name so you can upgrade clusters on older versions of Kix when you are ready. `kix upgrade` with no name upgrades the `kix` input and builds only its clusters. `kix upgrade <input>` upgrades another Kix input to match `kix` (or to `--to <version>`, no newer than `kix`) and builds that input's clusters. `kix upgrade <cluster>` moves one cluster to a newer input in `kix.toml` (`--to <input>`, defaulting to `kix`), compares its builds before and after, and shows the release notes between the two versions.
