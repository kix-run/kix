+++
kind = "error"
id = "K1895"
+++
Validation checks, scorecard rules, automatic `PodDisruptionBudget` generation,
and Helm chart resource ordering now evaluate `matchExpressions` as well as
`matchLabels` on label selectors. Previously, Kix read `matchLabels` alone.
This can stop a build that passed before. Validation checks 9 (a workload's
selector matches its pod template), 12 (a `NetworkPolicy` selects a pod), and
14 (a `PodDisruptionBudget` selects a pod) now fail when a selector's
`matchExpressions` match nothing. The new check 25 fails when a
`matchExpressions` entry has no key or an operator Kubernetes rejects. The
scorecard rules `architecture.distinctWorkloadSelectors` and
`architecture.monitorSelectorMatchesService` now judge selectors that use
`matchExpressions`, and they fail the build when the cluster sets
`scorecard.maxSeverity = "error"`. These failures start with `[K1895]`. To fix
one, change the selector so it matches the pods or Services it should. For a
`PodDisruptionBudget` over pods an operator creates, add the
`kix.run/operand-of` annotation. For a monitor whose Service Kix does not
render, add the `kix.run/monitors-external-service: "true"` annotation. When
your own `PodDisruptionBudget` selects a workload's pods with
`matchExpressions`, Kix no longer generates a second one for them, and the
next deploy removes the generated one.
