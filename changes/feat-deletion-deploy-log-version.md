+++
kind = "silent"
cli = ["--log-format json"]
+++
The `schema_version` of `kix deploy --log-format json` and `kix rollback --log-format json` moves to `2026-11-25`, because a delete's `ready` event (`kind: delete`, `state: ready`) now means that the object is gone from the cluster. Before, it meant that Kubernetes had accepted the delete request, and the object could still be waiting for its finalizers. Programs that check `schema_version` must accept the new date. Programs that treated a delete's `ready` event as the object being gone now read it correctly, and ones that expected it right after the request must allow for the wait.
