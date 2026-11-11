+++
kind = "added"
+++
`kix upgrade` moves a project to a newer version of Kix. It builds every cluster with the project's version and the new one, moves one minor release at a time when the new one does not build, and lists the release notes that apply and the objects that changed. `--preview` changes nothing, and `--min-age 7d` or `[upgrade] min-age` in `kix.toml` waits until a release is that old. `kix deploy` waits until each change to stored data is acknowledged with `kix upgrade --ack`. `KIX_RELEASE_SOURCE` names a mirror of kix.run to fetch releases from.
