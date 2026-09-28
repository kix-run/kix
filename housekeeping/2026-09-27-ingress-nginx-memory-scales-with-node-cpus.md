# 2026-09-27 · `kix/packages/ingress-nginx` · The ingress-nginx controller has no resource limits, and a fixed memory limit would be wrong on large nodes.

The chart (4.15.1) sets requests of 100m CPU and 90Mi and leaves limits
commented out; the package does the same, so `reliability.hasResourceLimits`
and `reliability.boundedResources` warn. nginx starts one worker per CPU
(`worker-processes: auto`). On a 32-CPU kind node the idle controller used
333Mi (`memory.current`), with 32 workers. A memory limit has to follow the
worker count, which the package does not set.
