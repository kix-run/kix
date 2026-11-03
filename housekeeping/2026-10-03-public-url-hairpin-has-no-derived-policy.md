# 2026-10-03 · `kix/lib/plugins/netpol` · A pod that dials another instance's public URL gets no egress to the ingress controller when Cilium replaces kube-proxy.

Harbor core and Immich discover Keycloak at its issuer, the public URL, and
both check that the issuer the provider reports matches it, so neither can
use Keycloak's Service address (go-oidc `NewProvider`, openid-client 6
`discovery`). cert-manager's HTTP-01 self-check also fetches the public URL.
The ingress controllers (ingress-nginx, traefik) admit `all-pods` on 80 and
443, so the controller side is open. The client side is not: the pods carry
only `world:443` or `world:80` egress. With kube-proxy, Cilium sees the load
balancer address and the request passes as `world`. With
`kubeProxyReplacement`, Cilium translates the address to the controller pod
before policy, the destination is in the cluster, and default deny drops it.
Nothing in `kix.expose` or the exposure record tells a client which pods
answer a public URL from inside the cluster. See the harbor and immich
headers.

Decision required from the Kix maintainers: whether an exposure record names
the pods behind its URL, so a client of that URL gets egress to them. This
touches where network intents live, which is an open design question.
