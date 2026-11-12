+++
kind = "fixed"
+++
`kix rollback` now sends its writes to the apiserver as a dry run before it changes anything, and stops if the apiserver would refuse one. Before, a field ownership conflict, such as a replica count set with `kubectl scale`, stopped the rollback halfway and left the cluster between two builds, and `--dry-run` did not show the conflict. The new `--force-conflicts` flag on `kix rollback` takes the fields another manager owns, which the error message already told users to do.
