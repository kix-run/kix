+++
kind = "changed"
cli = ["kix status"]
+++
`kix status` now reports when a deploy has failed since the current deploy, and exits `2` until a new deploy succeeds. Previously, because a failed deploy leaves the earlier deploy active, `kix status` checked only that earlier deploy and could report every object `ok` right after a deploy failed. Text output now shows the failed deploy first, along with when and why it failed, and checks any objects present only in the failed build under `Only in the failed deploy`. JSON and YAML output add `clusters[].failed_deploy` and `summary.failed_deploys`.
