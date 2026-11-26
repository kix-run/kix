+++
kind = "changed"
+++
Kix updates its Kubernetes client library to kube 5.2.0, which fixes advisory RUSTSEC-2026-0600 in the library's `openssl-tls` option. Kix was not affected, because it connects to clusters with rustls and does not use that option.
