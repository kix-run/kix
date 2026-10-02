# 2026-10-01 · `kix/lib/meta.nix` · The `meta.conflictsWith` error names the conflicting instances but not why they conflict or how to fix it.

A second tailscale instance fails with "conflicts with 'tailscale' (cluster-wide). Conflicting instances: …" (`conflictAssertions` in `kix/lib/meta.nix`). The package knows the reason (cluster-wide CRDs, a literal IngressClass name) only in a comment, so the reader has to open the package to learn that the fix is to remove one instance.
