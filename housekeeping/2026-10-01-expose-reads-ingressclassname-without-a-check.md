# 2026-10-01 · `kix/lib/vocab/compose.nix` · `kix.expose` reads `ingressNginx.out.ingressClassName` with no check, so a wired controller that lacks it fails with a bare "attribute missing".

`kix.expose` uses `ingressNginx.out.ingressClassName` to render the Ingress (two reads in `compose.nix`). A package wired as `ingressNginx` that publishes no such key, such as an import or a controller with a fixed class, fails the build with "attribute 'ingressClassName' missing" and no hint of which dependency or key is at fault.
