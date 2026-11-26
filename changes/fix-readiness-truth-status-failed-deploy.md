+++
kind = "silent"
cli = ["kix status"]
+++
Check any script that uses the exit code of `kix status`. `kix status` now exits `2` when a deploy has failed since the current deploy, until a new deploy succeeds. When a deploy fails, the previous deploy stays active. Before, `kix status` checked only that deploy and exited `0` when its objects passed. If a script should check only the current deploy, update it to read the top-level `summary` from `kix status -o json` instead of using the exit code. The current deploy is healthy when `missing`, `changed`, `not_ready`, `deleting`, and `leaving` are all `0`. JSON and YAML output count failed deploys separately in `summary.failed_deploys` and describe each one in `clusters[].failed_deploy`. Text output shows the failed deploy first, with when and why it failed, and checks any objects present only in the failed deploy under `Only in the failed deploy`.
