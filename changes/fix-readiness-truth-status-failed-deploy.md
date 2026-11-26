+++
kind = "silent"
cli = ["kix status"]
+++
`kix status` now exits `2` when a deploy has failed since the current deploy, even when every object of the current deploy passes its checks. Before, it exited `0` in that state, because a failed deploy leaves the earlier deploy current and `kix status` checked only that deploy. A script that uses the exit status as a health gate now fails after any failed deploy until a deploy succeeds. To keep the old meaning, run `kix status -o json` and read the top-level `summary`: the current deploy is healthy when `missing`, `changed`, `not_ready`, `deleting`, and `leaving` are all `0`. `summary.failed_deploys` counts the failed deploys apart from those, and `clusters[].failed_deploy` describes each one. Text output now shows the failed deploy first, with when and why it failed, and checks the objects present only in the failed build under `Only in the failed deploy`.
