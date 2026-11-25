+++
kind = "fixed"
packages = ["experimental/external-dns"]
library = ["kix.cloudIdentity.use", "kix.cloudIdentity.useIdentity"]
+++
Existing clusters and packages need no changes. When `external-dns` rejects a cloud identity, the evaluation error now identifies the `providerCredentials` dependency instead of leaving the dependency unnamed. Package authors calling `kix.cloudIdentity.use` or `kix.cloudIdentity.useIdentity` can pass the optional `arg` string (the dependency name in `deps`) so errors set the `dependency` field and name `deps.<arg>`, making it clear which dependency to fix when a package has more than one.
