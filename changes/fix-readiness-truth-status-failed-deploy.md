+++
kind = "changed"
cli = ["kix status"]
+++
`kix status` now reports a deploy that failed after the current one. A failed deploy leaves the previous deploy current, and `kix status` used to report only that deploy, so it could say every object was ok right after a deploy failed. The output now starts with the failed deploy, when it failed, and why, checks the objects only the failed build has, and exits `2`. The JSON output adds `clusters[].failed_deploy` and `summary.failed_deploys`.
