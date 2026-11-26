+++
kind = "error"
library = ["meta.network.intents", "meta.network.externalIngressEntities"]
id = "K2060"
+++
Replace any Cilium-only entity name (such as `"health"` or `"ingress"`) in `meta.network.intents`, `meta.network.externalIngressEntities`, or `networkPolicy.platformIntents` with `"world"`, `"host"`, `"remote-node"`, `"kube-apiserver"`, `"cluster"`, or `"all"`, or build a `CiliumNetworkPolicy` directly with `scope.mkCR` and `cilium.out.crds.CiliumNetworkPolicy`. Kix now rejects any other entity name during evaluation so intent rules stay portable across network policy enforcers.
