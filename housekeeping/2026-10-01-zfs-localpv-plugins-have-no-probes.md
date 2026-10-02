# 2026-10-01 · `kix/packages/zfs-localpv` · The controller and node `zfs-plugin` containers have no probes, so `reliability.hasProbes` warns four times and `kix deploy` counts them Ready once their processes start.

The controller sidecars serve `/healthz/leader-election`, and the node's
`node-driver-registrar` serves `/healthz` on `--http-endpoint=:9809`; all are
probed. The plugin serves no health endpoint of its own. The CSI convention
is a `livenessprobe` sidecar (registry.k8s.io/sig-storage/livenessprobe)
that calls the driver's Probe RPC on its socket. Upstream does not ship one,
and adding it means a new image option and port in both pods. The node pod
is not on the host network, so the port needs no per-node reservation.
