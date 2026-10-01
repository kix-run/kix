# 2026-10-01 · `kix/packages/zfs-localpv` · The ZFS plugin containers and the node registrar have no probes, so `reliability.hasProbes` warns six times and `kix deploy` counts them Ready once their processes start.

The controller sidecars serve `/healthz/leader-election` and are probed. The
controller and node `zfs-plugin` containers serve no health endpoint; the CSI
convention is a `livenessprobe` sidecar that calls the driver's Probe RPC on
its socket, which upstream does not ship. `node-driver-registrar` serves
`/healthz` only on an `--http-endpoint`, and the node pod runs on the host
network, so that port would have to be free on every node and unique per CSI
driver.
