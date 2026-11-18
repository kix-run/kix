+++
kind = "error"
packages = ["experimental/infisical-operator"]
id = "K6591"
+++
`experimental/infisical-operator` supports Kubernetes 1.29 to 1.33, as upstream's documentation states. A cluster on another minor release now fails the build with `[K6591]`. Move the cluster to a supported version, or keep the older Kix release until it can.
