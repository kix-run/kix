# 2026-10-02 · `kix/packages/envoy-gateway` · envoy-gateway fails four items of the package checklist.

- `meta.version = "1.1.0"` (`default.nix:95`), although the package deploys no upstream software: it writes only GatewayClass, Gateway and EnvoyProxy objects.
- The `proxySpec` assertion message starts with `envoy-gateway: ` (`:201`), and the lib prefixes the instance as well, so the name appears twice.
- The header is not the package header template, and the name suggests it installs Envoy Gateway, which it does not (the controller comes from elsewhere).
- `addresses` is `listOf anything` (`:159`), so a malformed Gateway address reaches the apiserver unchecked.
