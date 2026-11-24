+++
kind = "added"
library = ["cluster.defaultLimits", "kix.options.resources"]
+++
Set `cluster.defaultLimits.cpu = false` or `cluster.defaultLimits.memory = false`
to omit the default CPU or memory limits that packages set through
`kix.options.resources`. Both options default to `true`, so existing clusters
do not change. Resource requests and any limits set on an instance still apply,
and the `reliability.boundedResources` scorecard rule does not report containers
missing a disabled limit. Keep memory limits enabled unless you need to turn
them off: a container without a memory limit can use all of a node's memory and
cause the kernel to kill other workloads.
