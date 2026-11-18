+++
kind = "changed"
packages = ["experimental/gateway-api"]
+++
`gateway-api` now accepts `k8sVersion` 1.32 and versions newer than 1.37 instead of failing the build. When `k8sVersion` is 1.32 or newer than 1.37, the build succeeds with a warning because Gateway API v1.7.0 tests its CRDs on Kubernetes 1.33 to 1.37. `gateway-api` still refuses `k8sVersion` values below 1.32: its CRDs use CEL validation rules from the format library added in Kubernetes 1.32, which older API servers reject. Clusters that leave `k8sVersion` unset are not checked.
