+++
kind = "changed"
+++
`kix status <cluster>` and `kix snapshot <cluster>` accept the name a cluster has in `flake.nix`, as `kix rollback` and `kix history` do. For a cluster whose definition sets its own `name`, they used to need that name. The name on the deploy records still works.
