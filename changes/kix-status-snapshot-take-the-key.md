+++
kind = "changed"
+++
`kix status <cluster>` and `kix snapshot <cluster>` now accept the cluster's key in `flake.nix` (`clusters.<name>`) even when the cluster definition sets a different `name`, matching `kix rollback` and `kix history`. Passing the `name` recorded on the cluster still works, and both commands now accept `--flake` and `--override-input` when looking up a cluster in `flake.nix`.
