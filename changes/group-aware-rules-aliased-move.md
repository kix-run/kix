+++
kind = "error"
id = "K8031"
+++
If a build moves an `Event` between core `v1` and `events.k8s.io`, keep its current `apiVersion`, or first deploy a build without the `Event` using `kix deploy --prune` and then deploy a build with the new `apiVersion`. `kix plan`, `kix deploy`, and `kix rollback` now refuse moves between API groups that Kubernetes stores as the same object, because applying the new group and deleting from the old group deletes that object from the cluster.
