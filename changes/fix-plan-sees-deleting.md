+++
kind = "fixed"
+++
`kix deploy` and `kix rollback` now recreate resources that are missing from
the cluster or being deleted even when they have not changed since the current
deployment, and `kix plan` includes them in the plan. Planning finds these
resources by listing Kix-managed objects across the cluster once for each
resource kind in the build. If your Kubernetes account lacks cluster-wide
`list` permission for a kind, Kix prints a warning and skips unchanged
resources of that kind. Grant cluster-wide `list` permission for the kinds in
your build, or pass `--reconcile` on `kix plan` or `kix deploy` to reapply
every resource. Previously, Kix skipped unchanged resources without
`--reconcile`, so a deleted resource stayed missing and a resource being
deleted was removed after the deploy succeeded. Offline plans (`--offline`)
still read nothing from the cluster, and the Kix operator already recreated
missing or deleting resources.
