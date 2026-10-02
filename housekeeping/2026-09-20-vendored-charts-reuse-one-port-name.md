# 2026-09-20 · `kix/packages/cilium` · The vendored Cilium chart gives one port name two numbers, and we cannot rename it.

`architecture.consistentPortNames` now warns whenever one port name means
more than one number in an instance. One finding comes from an upstream Helm
chart rather than from our own code:

- `kube-system/cilium`: `health` is 9879 on the agent DaemonSet and 9234 on
  the operator Deployment.

The names come from `helm template`, so a rename would have to be a values
override or a post-render patch, and the chart's own probes and
ServiceMonitors use them. The warning fires in every cluster that installs
the package. Either the rule should skip a chart-imported workload, or the
package needs an override that says the clash is upstream's.
