+++
kind = "added"
library = ["cluster.defaultLimits", "kix.options.resources"]
+++
Existing clusters need no changes: the new `cluster.defaultLimits.cpu` and
`cluster.defaultLimits.memory` options both default to `"package"`. Set either
option to `"none"` to drop the default CPU or memory limits that packages
declare with `kix.options.resources`, while keeping all resource requests and
any limits set on individual instances. Setting a field of
`cluster.defaultLimits` to `"none"` also tells the `reliability.boundedResources`
scorecard rule not to require that limit. Keep `cluster.defaultLimits.memory`
set to `"package"` unless you set memory limits per instance or intend to run
without them, because a container without a memory limit can exhaust a node's
memory and cause the kernel to kill other pods on that node.
