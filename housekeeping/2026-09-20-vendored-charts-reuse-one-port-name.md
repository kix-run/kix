# 2026-09-20 · `kix/packages/{cilium,loki}` · Two vendored charts give one port name two numbers, and we cannot rename them.

`architecture.consistentPortNames` now warns whenever one port name means
more than one number in an instance. Two findings come from upstream Helm
charts rather than from our own code:

- `kube-system/cilium`: `health` is 9879 on the agent DaemonSet and 9234 on
  the operator Deployment.
- `monitoring-loki/loki`: `http-metrics` is 8080 on the gateway Deployment
  and 3100 on the loki StatefulSet.

The names come from `helm template`, so a rename would have to be a values
override or a post-render patch, and the chart's own probes and
ServiceMonitors use them. Both warnings will fire in every cluster that
installs either package. Either the rule should skip a chart-imported
workload, or those two packages need an override that says the clash is
upstream's.
