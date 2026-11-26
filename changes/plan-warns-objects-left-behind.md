+++
kind = "added"
+++
With `--prune`, `kix plan` and `kix deploy` warn when a CustomResourceDefinition
leaves the build while objects of its kind that the prune does not delete,
such as a Certificate made with `kubectl`, are still on the cluster. The
warning names up to 20 of them, those with finalizers first, because nothing
removes their finalizers or cleans up what they made outside the cluster once
the kind's controller is gone. The plan's JSON gives them in the new
`left_behind` field of the prune entry. Kix still allows the deploy.
