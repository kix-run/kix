+++
kind = "fixed"
+++
The `gke-autopilot` flavor now sets `cluster.capabilities.daemonSets = true` and `cluster.capabilities.multiNode = true`. Unprivileged DaemonSets, such as the `otel-collector` node agent, now build instead of failing evaluation, and builds no longer warn that `multiNode` is not set. DaemonSets that use privileged containers, `hostNetwork`, `hostPID`, or `hostPath` volumes still fail the build because `privilegedContainers` remains `false`. In addition, `kix deploy` no longer times out when a workload activates `platform-dns` on `gke-autopilot` or `openshift`. Previously, `kix deploy` looked for the DNS Service in the `platform-dns` instance's namespace instead of `kube-system` on `gke-autopilot` and `openshift-dns` on `openshift`.
