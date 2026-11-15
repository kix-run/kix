+++
kind = "added"
packages = ["experimental/gateway-api"]
+++
The `gateway-api` package installs the Gateway API standard-channel CRDs
(v1.6.1) and the upstream policy that refuses older or experimental-channel
CRDs over them. It claims the new `gatewayApi` role, so a cluster has one
set, and Gateway API implementations build their GatewayClass and Gateway
from its `out.crds`. On a cluster whose provider installs the CRDs, bind
`cluster.roles.gatewayApi` to `exclusive` and declare them with
`kix.mkImport`.
