# 2026-09-18 · `kix/lib/vocab/compose.nix` · `kix.expose` with `paths` throws on a Gateway API cluster.

Multi-backend routing only renders an Ingress. Harbor needs it, so harbor
cannot be exposed on ludo, which routes through a Gateway. The throw names
the mode but not the workaround, and there is none short of an Ingress
controller.
