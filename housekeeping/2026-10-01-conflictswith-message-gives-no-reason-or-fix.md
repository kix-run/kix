# 2026-10-01 · `kix/packages` · Most one-per-cluster packages give no reason in `meta.conflictsWith`, so their conflict error says only how to fix it.

A `meta.conflictsWith` entry can be `{ key; reason; }`, and Kix adds the reason to the conflict error (`conflictAssertions` in `kix/lib/meta.nix`). Only tailscale sets one. The other sixteen packages with a `cluster:` entry (stackgres-operator, cnpg-operator, cert-manager, kubevirt, cdi, velero, and others) still keep the reason in a header comment, so the user has to open the package to learn why a second instance is refused.
