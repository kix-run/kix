+++
kind = "added"
library = ["cluster.defaultLimits", "kix.options.resources"]
+++
Existing clusters need no changes: the new `cluster.defaultLimits.cpu` and
`cluster.defaultLimits.memory` options both default to `"package"`. Set either
option to `"none"` to omit the default CPU or memory limits that packages
declare with `kix.options.resources`. Resource requests and any limits set on an
instance still apply, and the `reliability.boundedResources` scorecard rule
skips checking a limit set to `"none"`. Leave `cluster.defaultLimits.memory` at
`"package"` unless you set memory limits per instance or deliberately run
without them, because a container with no memory limit can exhaust node memory
and cause the kernel to kill other pods on that node.
