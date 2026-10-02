# 2026-10-02 · `kix/packages/mayastor` · Nine mayastor containers run with a writable root filesystem.

`security.readOnlyRootfs` warns on agent-core, agent-ha-cluster, api-rest,
operator-diskpool, csi-controller, csi-node, agent-ha-node, io-engine, and
the metrics exporter. Upstream sets no read-only root on them, and their
write paths have not been observed: the node agents need hugepages, the
nvme_tcp module, and /run/udev, which a stock kind cluster lacks. Mapping
them needs the kind data-path run (`scripts/kind-mayastor.sh`) or a real
storage node.
