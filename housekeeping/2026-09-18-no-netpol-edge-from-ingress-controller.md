# 2026-09-18 · network policy · Nothing opens ingress on an exposed backend from the ingress controller's namespace.

On `clusters/test-harbor.nix` (ingress-nginx, `networkPolicy.enable`,
default deny) the core and portal pods get no CNP ingress rule from
`ingress-system`, so the controller cannot reach them. Check whether
`v2_discussions/96_*` already tracks this before treating it as new.
