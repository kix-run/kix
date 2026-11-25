+++
kind = "silent"
+++
`kix gc` now keeps every object in the build of the cluster's Active record, in the default mode and with `--full-scan`. Before, it compared the cluster with a build of your current files, so after `kix rollback` it planned to delete the workload the rollback restored, and after you edited the files it deleted what they dropped before a deploy created its replacement. To delete what you removed from the files, run `kix deploy --prune`, or run `kix deploy` and then `kix gc`. When the Active build is not on this machine and the current files make a different build, `kix gc` stops and deletes nothing. After a deploy or rollback without `--prune`, Kix now says to run `kix gc`, which no longer undoes a rollback.
