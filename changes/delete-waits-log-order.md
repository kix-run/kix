+++
kind = "changed"
+++
`kix deploy --prune`, `kix rollback --prune`, `kix gc`, and the Kix operator now delete up to 64 independent objects in parallel, so log lines and `--log-format json` events for pruned objects can interleave. In `--log-format line`, Kix now prints `will be deleted` (previously `still on the cluster`) when listing objects to prune, and `deleted` (previously `ready`) once each pruned object is gone.
