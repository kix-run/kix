# 2026-11-17 · `kix/lib/tests/units/cert-manager.nix` · Tests probe a tag with the next release, so a bump breaks them.

The cert-manager lib tests used `v1.21.3` as a tag that renders without a digest. When `release` moves to `v1.21.3`, the tag equals the pin, the digest attaches, and the tests fail. The bump moved the probe to `v1.21.2`. Such probes should use a tag that is not the pin and not the next release.
