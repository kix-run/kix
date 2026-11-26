+++
kind = "added"
library = ["kix.mkImport"]
+++
`kix.mkImport` now accepts an optional `namespace` argument when the imported resource lives in a different namespace from the import instance. Use it when the cluster blocks writes to the resource's namespace, such as `kube-system` on GKE Autopilot, so the import instance can live in another namespace. When `namespace` differs from the instance's namespace, Kix writes `kix.run/import-namespace` on the `PackageInstance` import marker, and build validation and `kix deploy` look for the resource there.
