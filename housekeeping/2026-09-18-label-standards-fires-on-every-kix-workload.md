# 2026-09-18 · `kix/lib/scope/builders.nix` · `governance.labelStandards` fires on every workload built with `mkWorkload`.

`mkWorkload` stamps only the instance and managed-by labels on the
workload's metadata. `app.kubernetes.io/name` lives in the selector
labels, which reach the pod template and nothing else. The packages that
pass the rule (ingress-nginx, valkey) set metadata labels by hand for Helm
parity; harbor sets `labels = componentSelector ...` on every workload for
the same reason.
