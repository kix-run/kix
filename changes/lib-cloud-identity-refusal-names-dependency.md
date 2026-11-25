+++
kind = "fixed"
packages = ["experimental/external-dns"]
library = ["kix.cloudIdentity.use", "kix.cloudIdentity.useIdentity"]
+++
When `kix.cloudIdentity.use` or `kix.cloudIdentity.useIdentity` refuses a cloud identity, the error now names the dependency that holds it, such as `deps.providerCredentials` on `external-dns`. Before, it said only "this dependency", so on a package with two credentials dependencies you had to guess which one to fix. Packages opt in with the new optional argument `arg`, the dependency's name, which also sets the error's `dependency` field.
