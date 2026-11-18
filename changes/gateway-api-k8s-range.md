+++
kind = "changed"
packages = ["experimental/gateway-api"]
+++
`gateway-api` now builds with a warning instead of failing when `k8sVersion` is 1.32 or newer than 1.37, outside the Kubernetes 1.33 to 1.37 range where Gateway API v1.7.0 tests its CRDs. It still refuses `k8sVersion` values below 1.32 because its CRDs use CEL validation rules from the format library added in Kubernetes 1.32, which older API servers reject. Clusters that leave `k8sVersion` unset are not checked.
