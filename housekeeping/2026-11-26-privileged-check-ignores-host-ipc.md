# 2026-11-26 · `kix/lib/scope/validators.nix` · `checkPrivileged` does not read `hostIPC`, and the capability's description says it covers it.

`cluster.capabilities.privilegedContainers` is documented in `kix/lib/modules.nix` and `cluster-configuration.mdx` as covering `hostIPC`. A pod with `hostIPC: true` builds on `gke-autopilot` and `openshift`, and the platform then refuses it. Adding it to the check makes a build that passes today fail, so it needs an `error` change record with an id.
