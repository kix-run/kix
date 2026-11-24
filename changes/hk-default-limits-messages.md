+++
kind = "changed"
packages = ["experimental/mayastor"]
+++
Default `experimental/mayastor` instances need no changes. `experimental/mayastor` now sets the `io-engine` container's memory limit to match `ioEngine.resources.requests.memory` (even when `cluster.defaultLimits.memory` is `"none"`) so the pod stays in the `Guaranteed` QoS class for exclusive CPU cores. If you set `ioEngine.resources.requests.memory` and want a different memory limit, set `ioEngine.resources.limits.memory` to a quantity. In addition, the `reliability.boundedResources` scorecard rule now warns about exhausting node memory only when `limits.memory` is missing; previously, it included that warning even when only CPU or request settings were missing.
