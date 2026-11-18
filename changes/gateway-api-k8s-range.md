+++
kind = "changed"
packages = ["experimental/gateway-api"]
+++
`gateway-api` now accepts a cluster whose `k8sVersion` is 1.32, or newer than 1.37, and warns when it is outside 1.33 to 1.37, the versions Gateway API v1.7.0 is tested on. It refused both before. It still refuses a `k8sVersion` older than 1.32, because its CRDs validate with a CEL library that Kubernetes provides from 1.32.
