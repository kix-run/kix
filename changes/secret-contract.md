+++
kind = "added"
library = ["kix.contracts.secret"]
+++
Packages can read a secret dependency through the stable contract
`kix.contracts.secret`. `kix.contracts.secret.helpers.use` checks that the
dependency is a secret and holds the keys the package reads.
`packages.secret`, `packages.secret-ref`, and every Secret built with
`scope.mkSecret` or `scope.mkSecretRef` honour it. A Secret that Kix fills
from a SOPS file also publishes `out.sops`, the file and its hash.
