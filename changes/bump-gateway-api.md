+++
kind = "changed"
packages = ["experimental/gateway-api"]
+++
`gateway-api` now installs Gateway API v1.7.0. The CRDs keep the same API versions, so existing Gateways and routes keep working, and HTTPRoute rules accept `retry` in the standard channel. The package now needs Kubernetes 1.33 or later. Its safe-upgrades `ValidatingAdmissionPolicy` now refuses Gateway API CRDs older than v1.7.0, so deploying an older `gateway-api` fails its dry run. To go back, delete the `ValidatingAdmissionPolicyBinding` named `safe-upgrades.gateway.networking.k8s.io`, then deploy the older version.
