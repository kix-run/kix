+++
kind = "fixed"
cli = ["kix deploy --log-format json"]
+++
`kix deploy --log-format json` now writes JSON output to stdout when there is nothing to apply or prune. Previously, stdout stayed empty, so scripts could not tell a deploy with nothing to change apart from one that stopped before applying. Kix now writes the `kubernetes` line (unless the build has no resources and never connects) and a `summary` line with `"succeeded": true`, all counts set to `0`, and `"nothing_to_apply": true`. Every other `summary` line sets `"nothing_to_apply": false`.
