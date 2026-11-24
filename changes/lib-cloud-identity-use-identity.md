+++
kind = "added"
library = ["kix.cloudIdentity.useIdentity", "kix.cloudIdentity.ambientProblem", "kix.cloudIdentity.use", "kix.cloudIdentity.annotationsFor"]
+++
Package authors can now support a cloud identity when one package owns the ServiceAccount and another package picks the cloud. `kix.cloudIdentity.useIdentity` reads a dependency that holds a cloud identity or nothing. It refuses a Secret and names where the Secret goes instead. `kix.cloudIdentity.ambientProblem` reports an error when a package reaches one cloud with the pod credentials of a dependency whose identity is for another cloud. `kix.cloudIdentity.use` takes an optional `identityGoesTo`, which its error names when the package refuses a cloud identity. `kix.cloudIdentity.annotationsFor` now accepts `identity = null` and returns empty sets.
