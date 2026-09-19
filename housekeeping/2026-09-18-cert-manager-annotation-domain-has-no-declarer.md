# 2026-09-18 · `kix/lib/rules/architecture.nix` · `cert-manager.io` annotations have no declarer, and declaring one moves the warning instead of removing it.

Every TLS Ingress carries `cert-manager.io/cluster-issuer`, stamped by
`clusterIssuer.out.withCert`, so `annotationDomainOwnership` reports the
domain as dead on every such cluster. Adding
`meta.annotationDomains = [ "cert-manager.io" ]` to cert-manager (tried
2026-09-18) makes every consumer warn instead: the rule wants a direct DI
dep on the declarer, and consumers depend on cluster-issuers, not
cert-manager. Declaring it on cluster-issuers would flag cert-manager's
own webhook annotations. The declarer is a dep of a dep, and the rule
cannot see that far.
