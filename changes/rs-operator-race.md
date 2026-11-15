+++
kind = "fixed"
+++
The Kix operator now runs one deploy per cluster at a time. A new `kix deploy --operator` or `kix rollback --operator` request waits until any in-progress deploy of that cluster finishes. Before, a new request could start while the operator was still deploying an earlier Activation record for the same cluster or resuming one after a restart, so two deploys wrote to the cluster at once.
