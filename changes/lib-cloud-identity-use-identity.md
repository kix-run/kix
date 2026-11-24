+++
kind = "added"
library = ["kix.cloudIdentity.useIdentity", "kix.cloudIdentity.ambientProblem", "kix.cloudIdentity.use", "kix.cloudIdentity.annotationsFor"]
+++
Existing clusters and packages need no changes. Package authors can now support cloud identities when one package owns the ServiceAccount and another chooses the cloud provider. `kix.cloudIdentity.useIdentity` reads an optional cloud identity dependency on the ServiceAccount owner, rejecting Secrets and pointing users to the location in `secretGoesTo`. `kix.cloudIdentity.ambientProblem` checks whether a target cloud conflicts with `out.identityCloud` on the dependency whose pods call the cloud API, returning `{ message, fix }` for `assertions` or `null`. `kix.cloudIdentity.use` accepts an optional `identityGoesTo` location for its error message when `cloud = null` rejects a cloud identity, and `kix.cloudIdentity.annotationsFor` accepts `identity = null` (returning empty `serviceAccountAnnotations` and `podLabels`).
