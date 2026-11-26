+++
kind = "error"
library = ["meta.network.intents", "meta.network.externalIngressEntities"]
id = "K2060"
+++
`entities` on a `meta.network.intents` rule or a `networkPolicy.platformIntents` rule, and `meta.network.externalIngressEntities`, accept only `world`, `host`, `remote-node`, `kube-apiserver`, `cluster`, and `all`. Any other Cilium entity name, such as `health` or `ingress`, now fails evaluation with `[K2060]`. Replace it with one of these names, or build that policy yourself with the `cilium` package's custom resource kinds.
