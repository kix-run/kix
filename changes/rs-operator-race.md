+++
kind = "fixed"
+++
The Kix operator deploys one Activation record of a cluster at a time. Before, a new `kix deploy --operator` request could start while the operator was still deploying, or resuming after a restart, an earlier record of the same cluster, so two deploys wrote to the cluster at once. The new record now waits until the earlier deploy finishes, then replaces it.
