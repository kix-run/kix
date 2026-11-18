+++
kind = "changed"
packages = ["experimental/keycloak"]
+++
`keycloak` now warns when the cluster's `k8sVersion` is outside the Kubernetes versions Keycloak 26.8 states support for, 1.31 to 1.34. The build still passes, because Keycloak calls no Kubernetes API and no version is known to fail. A cluster that sets no `k8sVersion` is not checked.
