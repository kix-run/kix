# 2026-11-07 · `kix/lib/helm.nix` · `importChart` leaves the Kubernetes version to Helm's built-in default.

`kubeVersion` defaults to null, so `helm template` runs without `--kube-version` and charts that branch on `.Capabilities.KubeVersion` follow whatever default the Helm binary has. Cilium (agent DaemonSet at `<1.30`, PDBs at `>=1.27`) and reflector (`startupProbe` at `>=1.18`) branch this way. Helm 3.19.1 and 4.3.1 may carry different defaults, so changing `helmVersion` or bumping Helm can change a render with no change to the package. `importChartCrds` already pins `1.32.0`.
