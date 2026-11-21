+++
kind = "added"
+++
`kix upgrade` takes a name in a project whose `kix.toml` has a `[versions]` table. `kix upgrade kix-stable` moves the input `kix-stable` to the version `kix` is on, or to the version `--to` names. `kix upgrade prod --to kix` moves the cluster `prod` to the input `kix`: Kix builds the cluster on both versions, shows what changes and the release notes between them, and lists the cluster under `kix` in `kix.toml`. `kix upgrade` with no name moves the input `kix`, and builds only the clusters on it.
