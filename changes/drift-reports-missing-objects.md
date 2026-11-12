+++
kind = "fixed"
+++
`kix drift` now reports an object that the cluster's current deployment record
lists and that is gone from the cluster, such as one removed with
`kubectl delete`. It shows as `MISSING`, counts in the summary, and makes the
command exit with 1. Before, `kix drift` checked only the objects still on the
cluster and reported everything in sync. In JSON output the resource has the
verdict `missing` and an `identityHash`, and the summary has a `missing` count.
