# 2026-11-17 · `scripts/check-bump.sh` · The check does not compare the platforms of a pinned image index.

Traefik v3.7.18 and v3.7.19 publish no `linux/riscv64` image, which v3.7.13 and v3.7.17 publish. The check passed for a bump to 3.7.19, so a package can drop a platform its users run on without any finding. Compare the platforms of the old and new index digests, for example with `docker manifest inspect` or the registry API. Decision required from the bump owner: whether a bump that drops a platform fails the check or only lists it.
