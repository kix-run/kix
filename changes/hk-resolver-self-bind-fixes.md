+++
kind = "fixed"
packages = ["experimental/cnpg-database", "experimental/stackgres-database", "experimental/mayastor"]
+++
Dependency resolution no longer binds an instance to itself. When an instance answered one of its own dependency names through its aliases, evaluation used to end in a stack overflow. Kix now skips the instance and binds another instance that answers the name, or reports the dependency as missing. A `deps.<name>` that points to the instance itself is refused. A dormant `optional = true` instance no longer fails the cluster when one of its required dependencies has no active provider. The warning for a post-hook that does not depend on `root` or a `root.requires` entry now fires, which it never did before. `cnpg-database` and `stackgres-database` now list their Database and bootstrap Job under `root.requires`, so each `PackageInstance` lists them in `kix.run/package-requires` and no longer in `kix.run/post-hooks`. Deploy order does not change.
