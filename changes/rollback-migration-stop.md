+++
kind = "error"
id = "K3354"
+++
When a rollback replaces a resource that holds data (such as a PersistentVolumeClaim or a database), back up or migrate the data first, then pass `--accept-migrations` to `kix rollback` or `kix rollback --operator`. Without `--accept-migrations`, both commands now stop before changing the cluster, print `[K3354]`, and list each replacement, matching `kix deploy`. Kix does not copy data between the old and new resources. Previously, `kix rollback` applied these replacements without stopping.
