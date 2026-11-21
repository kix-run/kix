+++
kind = "changed"
+++
`kix status <cluster>` and `kix snapshot <cluster>` now accept the cluster's key in `flake.nix` (`clusters.<name>`) even when the cluster definition sets a different `name`, matching `kix rollback` and `kix history`. Passing the deployed `name` still works. Both commands now also accept `--flake` and `--override-input` when looking up a cluster in `flake.nix`.
