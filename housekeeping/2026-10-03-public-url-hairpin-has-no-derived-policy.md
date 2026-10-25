# 2026-10-03 · `kix/lib/plugins/netpol` · An application that dials another instance's public URL from inside the cluster gets no derived policy.

Harbor core and Immich discover Keycloak at its issuer, the public URL, and
both check that the issuer the provider reports matches it, so neither can
use Keycloak's Service address (go-oidc `NewProvider`, openid-client 6
`discovery`). No string in their pod specs carries the route's context, so
no edge forms. Their `world:443` intents admit the request when the public
URL resolves to a load balancer outside the cluster. When Cilium or
kube-proxy serves that load balancer address inside the cluster, the
request reaches the ingress controller from a pod, and the controller's
derived policy admits only `world`, so sign-in fails under default deny.
Nothing in `kix.expose` or the exposure record says which pods answer a
public URL to a client inside the cluster. See the harbor and immich headers.
