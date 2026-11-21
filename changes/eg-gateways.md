+++
kind = "added"
packages = ["experimental/envoy-gateway", "experimental/cluster-issuer", "experimental/traefik"]
library = ["kix.expose", "kix.options.ingress", "kix.contracts.gateway"]
+++
`envoy-gateway` adds automatic TLS certificates, traffic and security policies,
HTTPS redirects, and proxy network policy controls. With a `clusterIssuer`
dependency (from a single `cluster-issuer` instance or a list in
`deps.clusterIssuer`), `envoy-gateway` creates a cert-manager `Certificate` for
each HTTPS listener without `tls.certificateRefs`, using the listener's
`hostname`, and `listenerIssuers` selects the issuer per listener when more
than one is wired. `clientTrafficPolicy` and `securityPolicy` create Envoy
Gateway `ClientTrafficPolicy` and `SecurityPolicy` resources attached to the
`Gateway` (covering minimum TLS version, trusted `X-Forwarded-For` CIDRs,
response headers such as `Strict-Transport-Security`, and IP allowlists).
`httpsRedirect` redirects HTTP listeners to HTTPS, and `clientSources` controls
whether the proxy network policy accepts traffic from `"world"`, `"all-pods"`,
or both.

`kix.options.ingress` and `kix.expose` also expand route configuration:
`ingress.annotations` now applies to `HTTPRoute` as well as `Ingress`,
`ingress.extraHosts` adds hostnames to a route, `ingress.timeouts` overrides a
package's `HTTPRoute` timeouts, and packages calling `kix.expose` can pass
`HTTPRoute` `filters` and `extraRules`. Finally, `kix.contracts.gateway` adds
an optional `public` boolean, which `envoy-gateway` and `traefik` set to
`false` when the Gateway `Service` is `ClusterIP` and `true` otherwise.
