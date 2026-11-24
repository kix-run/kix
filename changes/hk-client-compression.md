+++
kind = "changed"
+++
Kix now asks the Kubernetes API server and container registries for gzip-compressed answers. Commands that read many objects, such as `kix status`, `kix diff`, and `kix plan`, download about a tenth as much data, which makes them faster on a slow link. To turn compression off for a cluster, set `disable-compression: true` on that cluster in your kubeconfig.
