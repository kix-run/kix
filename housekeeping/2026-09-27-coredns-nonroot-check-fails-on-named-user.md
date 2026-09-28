# 2026-09-27 · `kix/packages/coredns` · CoreDNS pods never start: `runAsNonRoot` cannot verify the image's named user.

The coredns/coredns:1.13.1 image sets `USER nonroot`, a name rather than a
UID, and the container sets `runAsNonRoot = true` without `runAsUser`. The
kubelet refuses it with "container has runAsNonRoot and image has
non-numeric user (nonroot), cannot verify user is non-root", so every pod
sits in CreateContainerConfigError. Seen deploying `clusters/test-operators.nix`
to kind; `scripts/kind-operators.sh` fails its first check on it. Setting the
image's numeric UID (65532) in `runAsUser` would let the check pass.
