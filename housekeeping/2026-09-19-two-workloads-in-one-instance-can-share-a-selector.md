# 2026-09-19 · `kix/lib/scope/builders.nix` · Two workloads in one package instance can carry selectors that both match the same pods, and nothing warns.

`kix/packages/velero` set the server Deployment's `selector.matchLabels`
to the instance labels alone. The node-agent DaemonSet's pod template
carries those labels plus `name: node-agent`, so the Deployment selector
matched node-agent pods too. `kix deploy` then judged the Deployment's
health from a node-agent pod. The Service already worked around this by
adding `name: velero` to its own selector, which was the only sign
anything was wrong. The seal sees every workload in an instance, so it
could compare each selector against the other workloads' template labels
and refuse an overlap.
