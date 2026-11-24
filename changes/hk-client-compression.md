+++
kind = "changed"
+++
Kix now asks for gzip-compressed responses from the Kubernetes API server, and from container registries when you run `kix pin`. The API server compresses large responses, so `kix status`, `kix plan`, `kix snapshot`, and other commands that read many cluster resources download less data. To turn off API server compression for a cluster, set `disable-compression: true` on that cluster in your kubeconfig.
