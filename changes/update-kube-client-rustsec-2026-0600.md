+++
kind = "changed"
+++
Kix updates its Kubernetes client library to `kube` 5.2.0, which fixes advisory RUSTSEC-2026-0600 in `kube`'s `openssl-tls` feature. Earlier Kix versions were not affected because Kix connects to clusters with `rustls` and does not enable `openssl-tls`.
