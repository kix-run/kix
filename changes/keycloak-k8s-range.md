+++
kind = "error"
id = "K4417"
packages = ["experimental/keycloak"]
+++
`keycloak` now refuses a cluster whose `k8sVersion` is outside the Kubernetes versions Keycloak 26.8 supports, 1.31 to 1.34. It accepted every version before. If your cluster sets an older or newer `k8sVersion`, upgrade Kubernetes first, or stay on a Kix release with an older `keycloak` package. A cluster that sets no `k8sVersion` is not checked.
