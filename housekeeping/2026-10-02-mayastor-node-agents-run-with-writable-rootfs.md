# 2026-10-02 · `kix/packages/mayastor` · Four mayastor node-agent containers run with a writable root filesystem.

`security.readOnlyRootfs` warns on io-engine, the io-engine metrics exporter,
csi-node, and agent-ha-node. Upstream sets no read-only root on them, and
io-engine writes its RPC socket to `/var/tmp/mayastor.sock` by default (`-r`).
Their other write paths have not been observed: these pods need hugepages,
the nvme_tcp module, and /run/udev, which a stock kind cluster lacks. Mapping
them needs the kind data-path run (`scripts/kind-mayastor.sh`) or a real
storage node.
