+++
kind = "fixed"
cli = ["kix status", "kix plan --read-only"]
+++
After a deploy, `kix plan --read-only` no longer reports import markers (`kix.mkImport`, `scope.mkCRDRef`, `scope.mkSecretRef`, and `scope.mkServiceRef`) as objects that left the build and are still on the cluster. `kix status` also omits import markers instead of counting them as `ok` resources, and import-only packages such as `kube-system/platform-dns` no longer appear. Because import markers represent objects managed outside Kix, Kix never writes them to the cluster. If an earlier version of Kix applied a marker to the cluster, `kix plan --read-only` still lists it as an object that left the build until `kix deploy --prune` or `kix gc` deletes it.
