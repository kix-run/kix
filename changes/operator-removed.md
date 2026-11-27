+++
kind = "added"
state = true
cli = ["kix deploy --operator-removed", "kix plan --operator-removed"]
+++
`kix deploy <cluster> --operator-removed` takes a Kix cluster back from a Kix operator that was uninstalled. Kix refuses with `[K9557]` to change a Kix cluster whose current, queued, or deploying record was handed to an operator older than this version, and it cannot tell such an operator from one that was uninstalled. With the flag, the deploy first marks queued operator records `Superseded` and a record the operator was deploying `Failed`, and removes the operator's build path (`spec.source`) from them and from the current record. This happens before the plan is shown, so it also happens when you decline the plan. Later commands need no flag, unless `kix rollback` makes an older record the operator deployed current again. Do not use the flag while an older operator still runs. It cannot be combined with `--operator`. `kix plan --operator-removed` records the flag in the plan as `flags.operator_removed` and changes nothing.
