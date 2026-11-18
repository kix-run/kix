# 2026-11-18 · `kix/packages/experimental/volsync` · VolSync declares one readiness rule for every ReplicationSource and ReplicationDestination, and Syncthing sources and waiting rsync destinations never meet it.

The rule reads `status.latestMoverStatus.result`, which only restic, rclone, and rsync movers report. A Syncthing source, or an rsync destination that waits for its remote source, never reports it, so the deploy times out on them. `scope.mkCR` now takes `readiness` for one resource, so a builder in the package can pick the rule from the mover in the spec.
