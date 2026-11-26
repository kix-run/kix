+++
kind = "error"
id = "K6315"
cli = ["kix deploy --prune", "kix rollback --prune", "kix gc"]
+++
`kix deploy --prune`, `kix rollback --prune`, and `kix gc` now exit 1 when objects this cluster set out to delete are still on the cluster, and print `[K6315]` with how many were left. Previously they exited 0 and reported success, for example when a running operator stack stayed behind because one of its custom resources changed while Kix deleted it. Kix also stops leaving an object in place because its controller updated its status between Kix's read and its delete: Kix now reads and checks the object again and deletes it, and leaves it only after 5 refused deletes in a row. Objects that another Kix cluster still deploys stay as before and do not fail the run. The summary and the JSON `summary` line count these objects as `kept` (`left on the cluster` in text output), and `pruned` counts only the objects this run deleted. If your scripts treat exit 1 as a broken deploy, run `kix deploy --prune` or `kix gc` again to delete what was left.
