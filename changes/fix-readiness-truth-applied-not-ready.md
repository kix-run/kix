+++
kind = "added"
+++
The summary of `kix deploy` and `kix rollback` now says how many failed objects the run applied before they failed readiness, such as `0 configured, 1 failed (1 applied, then not ready)`. Each object still counts once, by how it ended, so such an object counts under `failed` and not under `configured`. The cluster holds its new spec all the same. The `summary` line of `--log-format json` adds the count as `failed_after_apply`.
