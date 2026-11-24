+++
kind = "changed"
+++
Kix now requests gzip-compressed responses from the Kubernetes API server and container registries. Commands that read many objects, such as `kix status`, `kix diff`, and `kix plan`, download less data and run faster on slow connections, because the API server compresses large responses. To disable compression for a cluster, set `disable-compression: true` on that cluster in your kubeconfig.
