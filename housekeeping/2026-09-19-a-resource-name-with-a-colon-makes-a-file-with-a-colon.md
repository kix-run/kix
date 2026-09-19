# 2026-09-19 · `kix/lib` · A resource whose Kubernetes name holds a colon writes a manifest file whose name holds a colon.

`kix/packages/kubevirt` builds the upstream ClusterRole
`kubevirt.io:operator`, and the build writes
`_cluster/kubevirt.io:operator-clusterrole.yaml`. The name is legal for
both Kubernetes and Linux, and `kubectl apply -f` reads the directory
fine. It bites a reader instead: an unquoted path in a shell breaks the
file into two words, and anything that splits a list of paths on a colon
sees two files. Upstream RBAC uses colons by convention, so more of
these will arrive.
