+++
kind = "error"
cli = ["kix deploy --operator --timeout"]
id = "K7218"
+++
Remove `--timeout` from `kix deploy --operator` commands. Passing `--timeout` with `--operator` now stops before building or changing the cluster. Previously, Kix accepted `--timeout` with `--operator` and ignored it. The Kix operator uses a fixed 300-second readiness timeout for each resource, and `--timeout` applies only when deploying without `--operator`.
