+++
kind = "fixed"
packages = ["experimental/zfs-localpv"]
+++
`zfs-localpv` now runs the OpenEBS ZFS driver 2.11.2 instead of 2.11.1. The first deploy restarts the controller and node pods once. The CRDs, RBAC, and StorageClasses do not change, so existing volumes and claims keep working, and you do not need to change anything. The package now accepts Kubernetes 1.23, the minimum the driver's README lists. Backup and restore transfers report `Failed` when either side of the transfer fails. Before, a failure on the sending side could still report `Done`. To go back, deploy the previous Kix version, which runs 2.11.1 again.
