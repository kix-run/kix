+++
kind = "changed"
packages = ["experimental/keycloak"]
+++
`keycloak` now warns when `k8sVersion` is outside Kubernetes 1.31 to 1.34, the versions corresponding to Keycloak 26.8's supported OpenShift releases (4.18 to 4.21). The build still succeeds because Keycloak does not call the Kubernetes API and no version is known to fail. Clusters that leave `k8sVersion` unset are not checked.
