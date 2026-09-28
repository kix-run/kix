# 2026-09-28 · `kix/packages/velero` · Repository maintenance fails for any velero instance not named `velero`.

Velero v1.15.2 builds each kopia maintenance Job from the server Deployment, which it looks up by the literal name `velero` in its namespace (`pkg/repository/manager/manager.go`, `buildMaintenanceJob`). The package names the Deployment after `scope.instanceName`, so an instance with another name deploys and backs up normally, but every maintenance run fails to find the Deployment and the repositories are never pruned. The package does not warn about this.
