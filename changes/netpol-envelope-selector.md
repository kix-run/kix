+++
kind = "added"
library = ["kix.operandPolicy"]
+++
`kix.operandPolicy` takes `selector` (the operand pods' labels), `ingress`, and `egress` in place of a whole Cilium `spec`. A policy written this way does not depend on Cilium's spec shape, so a future enforcer that writes standard `NetworkPolicy` can render it too. Every in-tree package now uses this form, and every built manifest stays the same. The `spec` argument still works.
