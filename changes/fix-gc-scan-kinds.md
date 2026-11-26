+++
kind = "changed"
cli = ["kix gc --full-scan"]
+++
`kix gc --full-scan`, `kix diff`, `kix plan`, and the Kix operator now read each object once, even when Kubernetes serves its kind under two API groups, such as an Event under `v1` and `events.k8s.io/v1`. Previously, `kix gc --full-scan` listed such an object twice. An object that carries Kix's labels but that Kix never wrote is now listed under "Copied labels" even when it has no `kix.run/identity-hash`, such as an Event that an operator posts with the labels of a custom resource. Previously, it was listed under "No deployment record on this cluster" or "No Kix build annotation". To check such an object, pass `--include copies,unstamped`, because it also has no `kix.run/identity-hash`. The line that says how many objects belong to other Kix clusters now names each cluster once, and its count of clusters matches the names. Previously, it repeated a cluster for each combination of clusters that shared objects.
