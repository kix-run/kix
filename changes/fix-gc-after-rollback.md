+++
kind = "silent"
+++
To delete resources you removed from your cluster files, run `kix deploy --prune`, or run `kix deploy` and then `kix gc`. Editing your files and running `kix gc` without deploying no longer deletes removed resources.

`kix gc` (both by default and with `--full-scan`) now keeps every resource in the build currently deployed on the cluster, as recorded on its `Active` deployment record. Previously, `kix gc` compared the cluster against your local files: running it after `kix rollback` planned to delete the resources the rollback had just restored, and running it with undeployed local edits deleted removed resources before `kix deploy` created their replacements. If the currently deployed build is not on this machine and your local files produce a different build, `kix gc` stops without deleting anything. When a deploy or rollback leaves old objects on the cluster, Kix now tells you to clean them up with `kix gc`.
