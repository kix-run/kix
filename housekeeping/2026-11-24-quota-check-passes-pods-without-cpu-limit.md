# 2026-11-24 · `kix/lib/vocab/quota-use.nix` · The build-time quota check passes a pod that a `limits.cpu` ResourceQuota will reject.

Kubernetes refuses a pod with no CPU limit in a namespace whose ResourceQuota sets `limits.cpu`, and the same holds for memory. `ofResources` (`kix/lib/vocab/quota-use.nix:61`) counts a missing limit as zero, so the build passes and the deploy fails. `cluster.defaultLimits.cpu = "none"` now removes CPU limits from every namespace at once, so a cluster with such quotas meets this on its first deploy.
