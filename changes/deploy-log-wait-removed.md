+++
kind = "silent"
cli = ["kix deploy --log-format json"]
+++
If a script or tool parses `kix deploy --log-format json`, remove any handling for `"kind": "wait"` on node events. That event kind was emitted only when a cluster waited for another cluster to install Kix's internal CustomResourceDefinitions, and Kix now installs those CRDs directly when a deploy starts.
