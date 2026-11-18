+++
kind = "changed"
packages = ["experimental/traefik"]
+++
`traefik` now warns when the cluster's `k8sVersion` is outside the Kubernetes versions Traefik states support for, 1.35 to 1.37. The build still passes, because no version is known to fail. A cluster that sets no `k8sVersion` is not checked.
