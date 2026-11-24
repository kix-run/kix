+++
kind = "error"
id = "K1895"
+++
If a build fails or warns with `[K1895]`, update the reported label selector or
the labels it targets. Every `matchExpressions` entry must be an object that
sets `key` and sets `operator` to `"In"`, `"NotIn"`, `"Exists"`, or
`"DoesNotExist"`. Each selector must match its intended pods or `Service`, and
workloads in the same package instance must not match each other's pods. If a
`PodDisruptionBudget` selects pods created by an operator, add the
`kix.run/operand-of` annotation (`"<group>/<Kind>/<name>"`). If a
`ServiceMonitor` or `VMServiceScrape` targets a `Service` created outside Kix,
add the `kix.run/monitors-external-service: "true"` annotation.

Kix now evaluates `matchExpressions` alongside `matchLabels` on label
selectors. Earlier releases checked `matchLabels` alone, so a build that passed
before can fail now. Build validation rejects malformed `matchExpressions`
entries and fails when a workload, `NetworkPolicy`, or `PodDisruptionBudget`
selector's `matchExpressions` match no pod template. The scorecard rules
`architecture.distinctWorkloadSelectors` and
`architecture.monitorSelectorMatchesService` also evaluate `matchExpressions`
now; they warn by default and fail the build when
`scorecard.maxSeverity = "error"`. In Helm charts, Kix now orders
`PodDisruptionBudget` and `ServiceMonitor` resources that use
`matchExpressions` after the workloads or `Service`s they select. When your own
`PodDisruptionBudget` selects a workload's pods with `matchExpressions`, Kix no
longer generates a second one, and the next deploy removes the previously
generated one.
