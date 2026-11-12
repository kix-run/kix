# 2026-11-12 · `kix/lib/rules/reliability.nix` · A container with no resource settings gets three warnings for one problem.

`boundedResources`, `hasResourceLimits`, and `hasResourceRequests` each fire on the same container. In kix-examples `homelab-kind`, 26 of the 41 warnings are these three rules on the same 9 containers (cilium, ingress-nginx).
