# 2026-10-01 · `kix/lib/scope/builders.nix` · A package cannot mark a one-pod workload as intended, so the capped-workload warning prints on every build.

`kix/packages/stable/harbor`: the exporter is one pod on purpose (a second doubles every Harbor-wide gauge), yet at `pod` and above every build prints its capped-workload warning. `availability.max` with a `reason` now explains the limit in the warning, but no form of it marks the singleton as intended so the warning stops.
