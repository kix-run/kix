+++
kind = "fixed"
+++
`kix deploy` and `kix rollback` without `--prune` now name only `kix gc <cluster>` as the way to delete the objects they kept, in the plan and in the deploy log, because `kix deploy --prune` after a rollback would undo it. `kix gc --full-scan` lists a package instance record under its instance, as it does the instance's other objects. When `cluster.kubernetes.uid` does not match the cluster Kix is connected to, the refusal lines up the two UIDs, suggests the wrong context first, and no longer prints a line that would bind the definition to the cluster it was refused on.
