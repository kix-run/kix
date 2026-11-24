+++
kind = "added"
library = ["kix.cloudIdentity.ambientProblem"]
+++
`kix.cloudIdentity.ambientProblem` now also takes `{ cloud; holderName; identityCloud; }` in place of `{ cloud; holder; }`. Use it in a builder in a package's own `out`, which has no dependency value for its own instance: pass `"${scope.namespaceName}/${scope.instanceName}"` and the identity's cloud. Both forms return the same result. Giving both forms, or neither, fails evaluation.
