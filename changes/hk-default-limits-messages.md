+++
kind = "changed"
packages = ["experimental/mayastor"]
+++
The `reliability.boundedResources` scorecard rule now warns that a workload can exhaust the node's memory only when a container has no memory limit. Before, it added that sentence to every finding, including one about a missing CPU limit alone. `experimental/mayastor` now sets the memory limit of `io-engine` equal to its memory request unless you set `ioEngine.resources.limits.memory`. The defaults are the same as before, so an instance that sets neither does not change.
