+++
kind = "silent"
packages = ["experimental/volsync"]
+++
`volsync` now runs VolSync 0.17.0 (was 0.16.0), with restic 0.19.1 and rclone 1.75.2 in its movers. The first deploy restarts the operator once. Restic repositories and the resources 0.16.0 wrote carry over, and the next backup continues from the last snapshot. The rsync mover over SSH (`spec.rsync`) now runs only in a namespace with the annotation `volsync.backube/privileged-movers: "true"`. Without it, the resource stops syncing and reports "rsync-ssh mover requires privileged mode", and the deploy shows no error. Set the annotation through `namespaces.<name>.annotations`, or move to the rsync-tls mover, which needs none. The CRDs add `moverTolerations` to each mover, and `restic.enableSparseRestore`, `restic.exclude.caches`, and the `restic.retain.within*` keys. To go back, deploy the previous Kix version.
