+++
kind = "added"
packages = ["experimental/cilium"]
+++
`cilium` (`packages.experimental.cilium`) adds a `failurePolicy` option (`"abort"`, `"reinstall"`, or `"retry"`) to set `spec.failurePolicy` on the `HelmChartConfig` when RKE2 or another `helm-controller` cluster installs Cilium. On RKE2 releases before 4 August 2026 (earlier than 1.33.13, 1.34.10, 1.35.7, or 1.36.3), set `failurePolicy = "abort"` so a failed Helm install or upgrade job leaves Cilium running instead of uninstalling it first. Those RKE2 releases default to `"reinstall"`, which removes Cilium from every node until the reinstall succeeds and leaves new pods without networking. Leave `failurePolicy` unset to keep your cluster's current behavior.
