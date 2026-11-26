+++
kind = "fixed"
cli = ["kix deploy --log-format json"]
+++
`kix deploy --log-format json` now writes JSON output to stdout when there is nothing to apply or prune. Previously, stdout stayed empty, so scripts could not tell a deploy with nothing to change apart from one that stopped before applying. Kix now writes the `kubernetes` line (unless the build has no resources, when Kix never connects) and a `summary` line with `"succeeded": true`, `"nothing_to_apply": true`, `unchanged` set to the number of unchanged objects, and all other counts set to `0`. Every other `summary` line sets `"nothing_to_apply": false`. Text output now includes the same count, as in `Nothing to apply (9 unchanged)`.
