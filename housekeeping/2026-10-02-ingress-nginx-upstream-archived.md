# 2026-10-02 · `kix/packages/ingress-nginx` · We ship ingress-nginx, and upstream archived it in March 2026.

The `kubernetes/ingress-nginx` repository is archived on GitHub, so the package
will get no more security fixes. Clusters that use it run an unpatched edge
proxy. `envoy-gateway` already covers Gateway API routing; Ingress users have no
maintained controller in kixpkgs.
