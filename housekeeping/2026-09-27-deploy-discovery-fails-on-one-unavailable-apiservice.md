# 2026-09-27 · `cli` · `kix deploy` stops before planning when one aggregated APIService is unavailable.

With CDI deployed, `v1beta1.upload.cdi.kubevirt.io` answered 503 while
`cdi-apiserver` was unreachable, and `kix deploy operators` gave up after
seven retries on `GET /apis/upload.cdi.kubevirt.io/v1beta1` with "could not
discover the resource types supported by the Kubernetes API". kubectl
reports the same group as a partial discovery failure and carries on. One
broken add-on API therefore blocks every deploy to the cluster, including
the deploy that would fix it.
