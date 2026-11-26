+++
kind = "fixed"
+++
Clusters with `networkPolicy.enable = true` no longer fail the build with `"the string ... is not allowed to refer to a store path"` when Prometheus or `VMAgent` scrapes a Service or monitor whose `name` comes from another resource's `.out` (such as the metrics Services in `external-secrets`). This affected both Cilium and standard `NetworkPolicy`.
