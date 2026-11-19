+++
kind = "added"
packages = ["experimental/cilium"]
+++
`cilium` has a new option, `failurePolicy`, for clusters where RKE2 installs Cilium. It sets what RKE2 does when its Helm job fails to install or upgrade Cilium: `"abort"`, `"reinstall"`, or `"retry"`. RKE2 releases older than 4 August 2026 (before 1.33.13, 1.34.10, 1.35.7, and 1.36.3) uninstall Cilium and install it again, which leaves new pods without a network until the install succeeds. On those releases, set `failurePolicy = "abort"`. Left unset, nothing changes.
