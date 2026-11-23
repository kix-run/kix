+++
kind = "fixed"
+++
The build checks, the scorecard rules, and the Helm ordering now read a label
selector's `matchExpressions` as well as its `matchLabels`. Before, they read
`matchLabels` alone, so a PodDisruptionBudget, a NetworkPolicy, or a
workload whose selector used `matchExpressions` was checked against the wrong
pods, and a ServiceMonitor or VMServiceScrape with `matchExpressions` was not
checked at all. A selector that matches no pods now fails the build with the
full selector in the message.
