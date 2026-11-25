+++
kind = "fixed"
cli = ["kix deploy --log-format json"]
+++
`kix deploy --log-format json` now writes a log when there is nothing to apply. Previously stdout stayed empty, so a program could not tell this run from one that stopped before printing. The log now holds the `kubernetes` line and a `summary` line with `"succeeded": true`, every count at 0, and the new field `"nothing_to_apply": true`. Every other `summary` line has `"nothing_to_apply": false`.
