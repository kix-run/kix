# 2026-11-26 · `kix/lib/scope/builders.nix` · The GKE host-network refusal ([K2669]) misses a workload changed by a `partsOverlays` entry.

The check runs in `_withCloudIdentity`, inside the workload builders. An overlay that sets `hostNetwork: true` on a built workload with `//` or `recursiveUpdate` never passes through a builder, so the pod runs as the node's service account without a refusal. A check over the final manifests (pod spec `hostNetwork` against the ServiceAccount's `kix.run/cloud-identity` record) would cover every path; the same gap likely applies to other builder-time checks.
