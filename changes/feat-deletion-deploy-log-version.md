+++
kind = "silent"
cli = ["--log-format json"]
+++
Update scripts and tools that read `kix deploy --log-format json` to accept `schema_version` `"2026-11-25"` and allow for finalizer cleanup before a delete finishes. Kix now emits a pruned object's completion event (`"type": "node"`, `"kind": "delete"`, `"verdict": {"state": "ready"}`) only after the object is gone from the cluster. Previously, Kix emitted that event as soon as Kubernetes accepted the delete request, while finalizers could still keep the object on the cluster.
