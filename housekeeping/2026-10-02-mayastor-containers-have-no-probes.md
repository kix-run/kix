# 2026-10-02 · `kix/packages/mayastor` · Twelve mayastor containers (thirteen when csi-snapshotter is rendered) have no liveness or readiness probe, so `reliability.hasProbes` warns for each.

Mayastor 2.12.1 probes only api-rest and etcd, and the package matches it.
Unprobed: agent-core, agent-ha-cluster, operator-diskpool, csi-controller
and its provisioner, attacher, and resizer sidecars, csi-node and its
registrar, agent-ha-node, io-engine, the io-engine metrics exporter, and,
with the snapshot API, the csi-snapshotter sidecar.
Most have no health endpoint; the CSI convention is the `livenessprobe`
sidecar on the driver socket, which on a host-network pod needs a host port.
`kix deploy` counts these containers Ready as soon as they start.
