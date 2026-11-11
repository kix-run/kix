+++
kind = "added"
+++
`kix upgrade` moves a project to a newer version of Kix. It builds every cluster with the project's version and the new one, moves one minor release at a time when the new one does not build, and lists the release notes in the range, marking those that likely affect the project, and the objects that changed. `--preview` changes nothing, and `[upgrade] min-age = "7d"` in `kix.toml` waits until a release is that old. `kix deploy` waits until each change to stored data is acknowledged with `kix upgrade --ack`, and refuses a cluster that would skip a release every cluster must deploy. `KIX_RELEASE_SOURCE` names a mirror of kix.run to fetch releases from.
