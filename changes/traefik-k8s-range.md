+++
kind = "error"
id = "K1871"
packages = ["experimental/traefik"]
+++
`traefik` now refuses a cluster whose `k8sVersion` is outside the Kubernetes versions Traefik supports and tests, 1.34 to 1.37. It accepted 1.32 and every later version before, and it now refuses 1.32, 1.33, and any version above 1.37. If your cluster sets an older or newer `k8sVersion`, upgrade Kubernetes first, or stay on a Kix release with an older `traefik` package. A cluster that sets no `k8sVersion` is not checked.
