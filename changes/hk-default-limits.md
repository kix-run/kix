+++
kind = "added"
library = ["cluster.defaultLimits", "kix.options.resources"]
+++
A cluster can turn off the default CPU limit or the default memory limit
that packages give their containers, with `cluster.defaultLimits.cpu = false`
or `cluster.defaultLimits.memory = false`. Requests stay, and so does a limit
an instance sets. The `reliability.boundedResources` rule then accepts the
missing limit. Keep memory limits unless you have a reason: a container
without one can use all of a node's memory, and the kernel then kills other
workloads.
