+++
kind = "added"
library = ["kix.cloudIdentity.ambientProblem"]
+++
Existing calls to `kix.cloudIdentity.ambientProblem` need no changes. `kix.cloudIdentity.ambientProblem` now also accepts `{ cloud; holderName; identityCloud; }` as an alternative to `{ cloud; holder; }`. Package authors can use this form in an `out` builder on the ServiceAccount owner (where no `holder` dependency exists), setting `holderName` to `"${scope.namespaceName}/${scope.instanceName}"` and `identityCloud` to the ServiceAccount's cloud (`"aws"`, `"gcp"`, `"azure"`, or `null`). Both forms return the same `{ message, fix }` error record or `null`; passing any other combination of arguments fails evaluation.
