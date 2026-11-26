+++
kind = "added"
+++
The summary of `kix deploy` and `kix rollback` now shows how many failed objects Kix applied before they failed readiness, such as `0 configured, 1 failed (1 applied but not ready)`. Kix counts each object once, so these objects appear under `failed` rather than `created` or `configured`, even though their new manifests are on the cluster. In `kix deploy --log-format json`, the `summary` object adds this count as `failed_after_apply`.
