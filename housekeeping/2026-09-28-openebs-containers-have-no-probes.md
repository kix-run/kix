# 2026-09-28 · `kix/packages/openebs` · 65 openebs containers have no liveness or readiness probe, so `reliability.hasProbes` warns 65 times.

The openebs chart 4.2.0 probes only api-rest, NATS, etcd and (liveness only)
localpv-provisioner, and the package matches it. Unprobed are the Mayastor
agents (agent-core, agent-ha-cluster, agent-ha-node, operator-diskpool,
csi-controller, csi-node, io-engine, the io-engine metrics exporter,
obs-callhome and its stats sidecar), every CSI sidecar in csi-controller,
csi-node and the ZFS and LVM controllers and nodes, the ZFS and LVM plugins,
and the NATS reloader and metrics sidecars. Most have no health endpoint;
the CSI convention is the `livenessprobe` sidecar on the driver's socket,
which upstream does not ship. `kix deploy` counts these containers Ready as
soon as their processes start.
