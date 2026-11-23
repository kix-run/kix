+++
kind = "fixed"
+++
Validation checks, scorecard rules, automatic `PodDisruptionBudget` generation,
and Helm chart resource ordering now evaluate `matchExpressions` as well as
`matchLabels` on label selectors. Previously, Kix read `matchLabels` alone, so
a workload, `NetworkPolicy`, or `PodDisruptionBudget` that used
`matchExpressions` could match the wrong pods or go unchecked when
`matchLabels` was empty. `ServiceMonitor` and `VMServiceScrape` selectors with
`matchExpressions` were also skipped. If a selector using `matchExpressions`
fails validation or a scorecard rule, `kix check` and `kix build` now report it
and show the full selector.
