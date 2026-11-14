+++
kind = "fixed"
state = true
+++
Kix now tells apart two kinds with the same name in different API groups, such as `Job` in `batch` and `Job` in `batch.volcano.sh`. Before, `kix deploy`, `kix plan`, `kix gc`, and the operator found an object's API by its kind alone, so on a cluster that served both they could read, change, or delete the object through the wrong group. Objects in the deploy log, the plan's `objects` list, and the deployment record's package index now carry a `group` field, left out for the core group. Records, logs, and plans written by earlier versions still read, and their objects count as core-group objects. A plan saved by an earlier version that deletes an object outside the core group no longer matches at `kix deploy --plan`, so make the plan again.
