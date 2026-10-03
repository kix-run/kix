# 2026-10-03 · `kix/packages/metrics-server` · The metrics.k8s.io APIService sets `insecureSkipTLSVerify`, so the API server does not verify metrics-server.

metrics-server signs its own serving certificate at startup in an emptyDir,
so the package has no CA to put in the APIService's `caBundle`. Anything that
can answer on the Service's address can serve pod and node metrics to the
HPA controller and to `kubectl top`. Upstream's components.yaml does the
same. A fix needs a certificate from cert-manager (or another issuer) mounted
through `--tls-cert-file` and `--tls-private-key-file`, and the issuer's CA in
`spec.caBundle`, as cert-manager's cainjector writes for other APIServices.
