# 2026-10-01 · `kix/packages/prometheus-default-rules` · On kind the control-plane monitors are on and their targets are always down.

With `monitoring.defaultRules.enabled = true` on kind (`ludo/base.nix`), the kube-controller-manager, kube-scheduler, kube-proxy and kube-etcd ServiceMonitors are on by default. kubeadm binds those metrics endpoints to 127.0.0.1, so Prometheus cannot reach them and `TargetDown` and the `Kube*Down` alerts fire permanently. `kix/lib/flavors/kind.nix` neither turns the monitors off nor sets the bind addresses.
