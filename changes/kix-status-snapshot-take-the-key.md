+++
kind = "changed"
+++
`kix status <cluster>` and `kix snapshot <cluster>` now accept the cluster's key in `flake.nix` (`clusters.<name>`) even when the cluster definition sets a different `name`, matching `kix rollback` and `kix history`. Passing the deployed `name` still works. When no deploy record on the Kubernetes cluster matches the given name, both commands now evaluate the project to look up the cluster's `name`, which takes longer than before. If the project cannot be loaded, they print a warning and look for the name as given. Both commands now also accept `--flake` and `--override-input` when looking up a cluster in `flake.nix`.
