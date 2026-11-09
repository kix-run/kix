# 2026-09-27 · `docs/nix/output-transforms.nix` · The drift view leaves short activation hashes and build-identity fields unredacted.

`nix run ./docs#regen-captures -- --check` reports drift in sidecars whose
content changes with the commit, the Nix version or the host, although Kix
behaves the same. `redact-identity-hash` matches only 32-character hashes,
so the 8-character prefix in `Active activation: <name> (aq1zdgf9...)` and in
`kix rollback --list` is never redacted. `redact-nar-hash` matches
`narHash=sha256-…` but not the JSON form `"narHash": "sha256-…"`. In
`how-to/application-receipt/active-receipt.json` and
`how-to/policy-receipt-attestation/attest.json`, `flakeLock`, `rev`,
`gitCommit`, `narHash` and `nixVersion` move with the commit and Nix version
(checked in: rev 6c584f5, Nix 2.28.5), and `arch` and `os` move with the host
(checked in: aarch64 macOS). Every live refresh rewrites these sidecars.
