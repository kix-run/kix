# 2026-10-02 · `kix/packages/n8n/default.nix` · The header comment names an option that does not exist.

The n8n header tells a reader to "open the namespaces with `namespaces.<ns>.networkPolicies.directions`". `namespaces.<ns>.networkPolicies` is an attribute set of Kubernetes NetworkPolicy specs, each named by its key, and has no `directions` field. The cluster-wide setting is `networkPolicy.directions`. A reader who follows the comment writes a NetworkPolicy called `directions`.
