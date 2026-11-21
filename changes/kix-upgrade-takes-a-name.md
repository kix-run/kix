+++
kind = "added"
+++
In projects with a `[versions]` table in `kix.toml`, `kix upgrade` now accepts an input name or a cluster name so you can upgrade held-back clusters when you are ready. Run `kix upgrade` with no arguments to upgrade the `kix` input and build only its clusters. Run `kix upgrade <input>` (with optional `--to <version>`) to upgrade another Kix input up to the version `kix` pins and build the clusters on that input. Run `kix upgrade <cluster>` (with optional `--to <input>`, defaulting to `kix`) to move one cluster to a newer input in `kix.toml`, compare its builds before and after, and review the release notes between the two versions.
