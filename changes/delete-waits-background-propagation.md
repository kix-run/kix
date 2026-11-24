+++
kind = "changed"
+++
`kix gc` and the Kix operator now delete resources with `Background` propagation, matching `kix deploy --prune`. Deleting a removed Job or ReplicationController now also deletes its pods, which previously stayed on the cluster.
