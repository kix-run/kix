+++
kind = "added"
library = ["kix.operandPolicy"]
+++
Existing `kix.operandPolicy` calls that pass `spec` continue to work without changes, and built manifests are unchanged. For new policies over operator-managed pods, pass `selector` (the pods' `matchLabels`), `ingress`, and `egress` to `kix.operandPolicy` instead of a Cilium `spec` so the policy stays independent of Cilium's resource format.
