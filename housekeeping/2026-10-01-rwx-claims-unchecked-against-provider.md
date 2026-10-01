# 2026-10-01 · `kix/packages/persistent-volume-claim` · A ReadWriteMany claim is not checked against what its StorageClass supports.

`accessModes = [ "ReadWriteMany" ]` builds against any `storageClasses`
provider, including block drivers that only offer ReadWriteOnce. The claim
then stays Pending in the cluster, with no build error. No provider
publishes the access modes it supports in `out`, so the package has nothing
to check against. The kix-migration skill (`SKILL.md`, the storage role
lines) and HANDBOOK §15 (the paragraph after the capability matrix) say
providers publish `rwx` and snapshot facts; none does.
